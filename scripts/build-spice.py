#!/usr/bin/env python3
"""Build the pinned CocoaSpice client and its Metal renderer for the local app."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
REVISION = json.loads((ROOT / "scripts/runtime-lock.json").read_text())["cocoaspice_revision"]
BUILD = ROOT / "build" / "spice"
REPOSITORY = BUILD / "CocoaSpice"
RESOURCES = Path(sys.argv[1])


def run(*args):
    subprocess.run(args, check=True)


def replace_once(source, original, replacement):
    if source.count(original) != 1:
        raise RuntimeError("Unexpected CocoaSpice renderer source")
    return source.replace(original, replacement, 1)


BUILD.mkdir(parents=True, exist_ok=True)
if not REPOSITORY.exists():
    run("git", "init", "--quiet", str(REPOSITORY))
    run("git", "-C", str(REPOSITORY), "remote", "add", "origin", "https://github.com/utmapp/CocoaSpice.git")
if subprocess.run(
    ["git", "-C", str(REPOSITORY), "cat-file", "-e", REVISION],
    stderr=subprocess.DEVNULL,
).returncode:
    run("git", "-C", str(REPOSITORY), "fetch", "--depth=1", "origin", REVISION)

sources = BUILD / "Sources"
if sources.exists():
    shutil.rmtree(sources)
sources.mkdir()
# Extract the pinned tree instead of building from mutable checkout files.
archive = subprocess.check_output(["git", "-C", str(REPOSITORY), "archive", REVISION])
subprocess.run(["tar", "-xf", "-", "-C", str(sources)], input=archive, check=True)

client = sources / "Sources" / "CocoaSpice"
renderer = sources / "Sources" / "CocoaSpiceRenderer"
# The renderer's public protocol lives in CocoaSpice upstream. Put it in the
# renderer module so both modules see one complete declaration.
shutil.move(client / "include" / "CSRenderer.h", renderer / "include" / "CSRenderer.h")
for path in [client / "include" / "CSDisplay+Renderer.h", client / "include" / "CocoaSpice.h"]:
    path.write_text(path.read_text().replace('#import "CSRenderer.h"', "@import CocoaSpiceRenderer;"))
main_source = client / "CSMain.m"
# The local console has no SPICE audio channels and does not link iOS plugins.
code = replace_once(main_source.read_text(), '#import "gst_ios_init.h"\n', "")
main_source.write_text(replace_once(code, "    gst_ios_init();\n", ""))
connection_source = client / "CSConnection.m"
connection_code = replace_once(
    connection_source.read_text(),
    "        display.isEnabled = YES;",
    """        display.isEnabled = YES;
        // The firmware's primary surface can arrive before a monitor configuration.
        [self.delegate spiceDisplayCreated:self display:display];""",
)
# A monitor configuration can arrive after a GL scanout during reconnect.
# Only the display channel closing actually destroys the primary display.
connection_source.write_text(replace_once(
    connection_code,
    "    } else {\n        [self.delegate spiceDisplayDestroyed:self display:display];\n    }",
    "    } else {\n        [self.delegate spiceDisplayUpdated:self display:display];\n    }",
))
display_source = client / "CSDisplay.m"
display_source.write_text(replace_once(
    display_source.read_text(),
    "    self.shadowNeedsFullCopy = YES;\n}",
    "    self.shadowNeedsFullCopy = YES;\n    [self updateVisibleAreaWithRect:self.canvasArea];\n}",
))
code = display_source.read_text()
start = code.index("        if (spice_channel_test_capability")
end = code.index("        goto whole;", start)
display_source.write_text(code[:start] + code[end:])
headers = BUILD / "Modules"
headers.mkdir(exist_ok=True)
for module, directory in [("CocoaSpiceNoUsb", client), ("CocoaSpiceRenderer", renderer)]:
    # CocoaSpice imports these modules directly from Objective-C.
    module_dir = headers / module
    module_dir.mkdir(exist_ok=True)
    include = module_dir / "include"
    if not include.is_symlink():
        include.symlink_to(directory / "include", target_is_directory=True)
    (module_dir / "module.modulemap").write_text(
        f'module {module} {{ umbrella "include" export * }}\n'
    )

# Runtime shader compilation lets a stock Xcode installation build the app.
# Keep the upstream shader and C/Metal layouts in sync.
shader = (renderer / "CSShaders.metal").read_text()
types = (renderer / "include" / "CSShaderTypes.h").read_text()
(RESOURCES / "CocoaSpiceShaders.metal").write_text(
    replace_once(shader, '#import "include/CSShaderTypes.h"', types)
)
renderer_source = renderer / "CSMetalRenderer.m"
renderer_code = renderer_source.read_text()
start = renderer_code.index("        // Load all the shader files")
end = renderer_code.index("        // Load the vertex function", start)
renderer_code = renderer_code[:start] + """        // Windows VM compiles the bundled upstream shader on first use.
        NSURL *shaderURL = [NSBundle.mainBundle URLForResource:@"CocoaSpiceShaders" withExtension:@"metal"];
        NSString *shader = shaderURL ? [NSString stringWithContentsOfURL:shaderURL encoding:NSUTF8StringEncoding error:&error] : nil;
        id<MTLLibrary> defaultLibrary = shader ? [_device newLibraryWithSource:shader options:nil error:&error] : nil;
        if (!defaultLibrary) {
            NSLog(@"Could not load the SPICE Metal shader: %@", error);
            return nil;
        }

""" + renderer_code[end:]
renderer_code = replace_once(
    renderer_code,
    '        NSAssert(_pipelineState, @"Failed to create pipeline state to render to texture: %@", error);',
    '        if (!_pipelineState) { NSLog(@"Could not create the SPICE Metal pipeline: %@", error); return nil; }',
)
renderer_code = replace_once(renderer_code, "- (BOOL)_renderCommand:", "- (void)_renderCommand:")
# Avoid repeatedly acquiring CAMetalLayer drawables while the guest is idle.
# Request a new frame after the view size changes, even for a static desktop.
renderer_code = replace_once(
    renderer_code,
    "    [self _setViewportCGSize:size];\n}",
    "    [self _setViewportCGSize:size];\n    self.renderNeedsUpdate = YES;\n}",
)
start = renderer_code.index("    // Obtain a renderPassDescriptor")
end = renderer_code.index("    // Consume the flag", start)
renderer_code = renderer_code[:start] + """    const _CSRendererSourceData *sourceData = self.renderSourceData;
    if (!self.renderNeedsUpdate || !sourceData.isVisible) {
        [self _completeDraw];
        return;
    }

    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> currentDrawable = view.currentDrawable;
    if (!renderPassDescriptor || !currentDrawable) {
        [self _completeDraw];
        return;
    }

""" + renderer_code[end:]
renderer_source.write_text(replace_once(renderer_code, "(nonnull instancetype)initWithMetalKitView",
                                       "(nullable instancetype)initWithMetalKitView"))
renderer_header = renderer / "include" / "CSMetalRenderer.h"
header = replace_once(renderer_header.read_text(), "(nonnull instancetype)initWithMetalKitView",
                      "(nullable instancetype)initWithMetalKitView")
renderer_header.write_text(replace_once(header, "@protocol CSRenderer;", '#import "CSRenderer.h"'))
notice = RESOURCES / "ThirdParty"
notice.mkdir(exist_ok=True)
shutil.copyfile(sources / "LICENSE", notice / "CocoaSpice-LICENSE.txt")

objects = BUILD / "Objects"
if objects.exists():
    shutil.rmtree(objects)
objects.mkdir(exist_ok=True)
external = client / "ExternalHeaders"
includes = [client / "include", renderer / "include", external]
includes += [external / name for name in ("glib-2.0", "gstreamer-1.0", "spice-client-glib-2.0", "spice-1")]
module_flags = [f"-fmodule-map-file={path}" for path in sorted(headers.glob("*/module.modulemap"))]
clang_flags = [
    "-fobjc-arc", "-fmodules", "-O2", "-target", "arm64-apple-macos14.0",
    f"-fmodules-cache-path={BUILD / 'module-cache'}", *module_flags,
    *[f"-I{include}" for include in includes],
]


def compile_source(path):
    run("xcrun", "clang", *clang_flags, "-c", str(path), "-o", str(objects / (path.stem + ".o")))


files = [path for path in sorted(client.glob("CS*.m")) if not path.name.startswith("CSUSB")]
with ThreadPoolExecutor(max_workers=2) as pool:
    list(pool.map(compile_source, [*files, renderer_source]))
