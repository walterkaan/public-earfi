#!/usr/bin/env python3
"""Write RoomCastGo.xcodeproj. Run again after adding a Swift or Opus source."""

from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "RoomCastGo.xcodeproj"


def uid(key: str) -> str:
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()


def q(value: str) -> str:
    if value == "" or any(ch in value for ch in " <>=;$()"):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


def file_type(path: Path) -> str:
    name = path.name
    if name.endswith(".swift"):
        return "sourcecode.swift"
    if name.endswith(".c"):
        return "sourcecode.c.c"
    if name.endswith(".h"):
        return "sourcecode.c.h"
    if name.endswith(".entitlements"):
        return "text.plist.entitlements"
    if name.endswith(".xcprivacy") or name.endswith(".plist"):
        return "text.plist.xml"
    if name.endswith(".xcassets"):
        return "folder.assetcatalog"
    if name.endswith(".xcframework"):
        return "wrapper.xcframework"
    return "text"


def main() -> None:
    swift = sorted((ROOT / "RoomCastGo").glob("*.swift"))
    opus = sorted((ROOT / "Vendor" / "opus").rglob("*.c"))
    bridge = ROOT / "Vendor" / "opus-bridge" / "opus_bridge.c"
    sources = swift + opus + [bridge]
    extras = [
        ROOT / "RoomCastGo" / "Info.plist",
        ROOT / "RoomCastGo" / "RoomCastGo.entitlements",
        ROOT / "RoomCastGo" / "RoomCastGo-Bridging-Header.h",
        ROOT / "RoomCastGo" / "PrivacyInfo.xcprivacy",
        ROOT / "RoomCastGo" / "Assets.xcassets",
    ]
    framework = Path("build/Roomcast.xcframework")
    resources = [
        ROOT / "RoomCastGo" / "Assets.xcassets",
        ROOT / "RoomCastGo" / "PrivacyInfo.xcprivacy",
    ]

    def rel(path: Path) -> str:
        return path.relative_to(ROOT).as_posix()

    file_refs: dict[str, str] = {}
    for path in sources + extras:
        file_refs[rel(path)] = uid("file:" + rel(path))
    framework_ref = uid("file:build/Roomcast.xcframework")
    product_ref = uid("file:RoomCastGo.app")

    source_builds = [(uid("build:" + rel(path)), file_refs[rel(path)]) for path in sources]
    resource_builds = [(uid("res:" + rel(path)), file_refs[rel(path)]) for path in resources]
    link_build = uid("build:link-framework")
    embed_build = uid("build:embed-framework")

    sources_phase = uid("phase:sources")
    frameworks_phase = uid("phase:frameworks")
    resources_phase = uid("phase:resources")
    embed_phase = uid("phase:embed")
    script_phase = uid("phase:script")
    target = uid("target:RoomCastGo")
    project = uid("project")
    main_group = uid("group:main")
    app_group = uid("group:app")
    vendor_group = uid("group:vendor")
    products_group = uid("group:products")
    target_list = uid("configlist:target")
    project_list = uid("configlist:project")
    target_debug = uid("config:target-debug")
    target_release = uid("config:target-release")
    project_debug = uid("config:project-debug")
    project_release = uid("config:project-release")

    lines: list[str] = []
    w = lines.append
    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {")
    w("\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")
    w("")
    w("/* Begin PBXBuildFile section */")
    for build_id, ref in source_builds + resource_builds:
        w(f"\t\t{build_id} /* build */ = {{isa = PBXBuildFile; fileRef = {ref}; }};")
    w(f"\t\t{link_build} /* Roomcast.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {framework_ref}; }};")
    w(
        f"\t\t{embed_build} /* Roomcast.xcframework in Embed */ = {{isa = PBXBuildFile; fileRef = {framework_ref}; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};"
    )
    w("/* End PBXBuildFile section */")
    w("")
    w("/* Begin PBXFileReference section */")
    for path in sources + extras:
        ref = file_refs[rel(path)]
        w(
            f"\t\t{ref} /* {path.name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type(path)}; path = {q(rel(path))}; sourceTree = SOURCE_ROOT; }};"
        )
    w(
        f"\t\t{framework_ref} /* Roomcast.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = {q(framework.as_posix())}; sourceTree = SOURCE_ROOT; }};"
    )
    w(
        f"\t\t{product_ref} /* RoomCastGo.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = RoomCastGo.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    w("/* End PBXFileReference section */")
    w("")
    w("/* Begin PBXGroup section */")
    app_children = [file_refs[rel(path)] for path in swift + extras]
    vendor_children = [file_refs[rel(path)] for path in opus + [bridge]]
    w(f"\t\t{app_group} /* RoomCastGo */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for ref in app_children:
        w(f"\t\t\t\t{ref},")
    w("\t\t\t);")
    w("\t\t\tname = RoomCastGo;")
    w('\t\t\tsourceTree = "<group>";')
    w("\t\t};")
    w(f"\t\t{vendor_group} /* Vendor */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for ref in vendor_children:
        w(f"\t\t\t\t{ref},")
    w("\t\t\t);")
    w("\t\t\tname = Vendor;")
    w('\t\t\tsourceTree = "<group>";')
    w("\t\t};")
    w(f"\t\t{products_group} /* Products */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{product_ref},")
    w("\t\t\t);")
    w("\t\t\tname = Products;")
    w('\t\t\tsourceTree = "<group>";')
    w("\t\t};")
    w(f"\t\t{main_group} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{app_group},")
    w(f"\t\t\t\t{vendor_group},")
    w(f"\t\t\t\t{framework_ref},")
    w(f"\t\t\t\t{products_group},")
    w("\t\t\t);")
    w('\t\t\tsourceTree = "<group>";')
    w("\t\t};")
    w("/* End PBXGroup section */")
    w("")
    w("/* Begin PBXNativeTarget section */")
    w(f"\t\t{target} /* RoomCastGo */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {target_list};")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{script_phase},")
    w(f"\t\t\t\t{sources_phase},")
    w(f"\t\t\t\t{frameworks_phase},")
    w(f"\t\t\t\t{resources_phase},")
    w(f"\t\t\t\t{embed_phase},")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w("\t\t\tname = RoomCastGo;")
    w("\t\t\tproductName = RoomCastGo;")
    w(f"\t\t\tproductReference = {product_ref};")
    w('\t\t\tproductType = "com.apple.product-type.application";')
    w("\t\t};")
    w("/* End PBXNativeTarget section */")
    w("")
    w("/* Begin PBXProject section */")
    w(f"\t\t{project} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w('\t\t\tattributes = {')
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastUpgradeCheck = 1600;")
    w("\t\t\t\tTargetAttributes = {")
    w(f"\t\t\t\t\t{target} = {{")
    w("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    w("\t\t\t\t\t};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w(f"\t\t\tbuildConfigurationList = {project_list};")
    w('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    w("\t\t\tdevelopmentRegion = en;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t);")
    w(f"\t\t\tmainGroup = {main_group};")
    w(f"\t\t\tproductRefGroup = {products_group};")
    w('\t\t\tprojectDirPath = "";')
    w('\t\t\tprojectRoot = "";')
    w("\t\t\ttargets = (")
    w(f"\t\t\t\t{target},")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")
    w("")
    w("/* Begin PBXCopyFilesBuildPhase section */")
    w(f"\t\t{embed_phase} /* Embed Frameworks */ = {{")
    w("\t\t\tisa = PBXCopyFilesBuildPhase;")
    w('\t\t\tbuildActionMask = 2147483647;')
    w('\t\t\tdstPath = "";')
    w("\t\t\tdstSubfolderSpec = 10;")
    w("\t\t\tfiles = (")
    w(f"\t\t\t\t{embed_build},")
    w("\t\t\t);")
    w("\t\t\tname = \"Embed Frameworks\";")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXCopyFilesBuildPhase section */")
    w("")
    w("/* Begin PBXFrameworksBuildPhase section */")
    w(f"\t\t{frameworks_phase} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w(f"\t\t\t\t{link_build},")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")
    w("")
    w("/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{resources_phase} /* Resources */ = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for build_id, _ref in resource_builds:
        w(f"\t\t\t\t{build_id},")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")
    w("")
    w("/* Begin PBXShellScriptBuildPhase section */")
    w(f"\t\t{script_phase} /* Check framework */ = {{")
    w("\t\t\tisa = PBXShellScriptBuildPhase;")
    w("\t\t\talwaysOutOfDate = 1;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w("\t\t\t);")
    w("\t\t\tinputFileListPaths = (")
    w("\t\t\t);")
    w("\t\t\tinputPaths = (")
    w("\t\t\t);")
    w('\t\t\tname = "Check Roomcast.xcframework";')
    w("\t\t\toutputFileListPaths = (")
    w("\t\t\t);")
    w("\t\t\toutputPaths = (")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w('\t\t\tshellPath = /bin/sh;')
    w(
        '\t\t\tshellScript = "if [ ! -d \\"$SRCROOT/build/Roomcast.xcframework\\" ]; then\\n'
        '  echo \\"error: build/Roomcast.xcframework is missing. In Terminal, cd into ios/RoomCastGo and run ./scripts/build-server-framework.sh\\" >&2\\n'
        '  exit 1\\n'
        'fi\\n";'
    )
    w("\t\t};")
    w("/* End PBXShellScriptBuildPhase section */")
    w("")
    w("/* Begin PBXSourcesBuildPhase section */")
    w(f"\t\t{sources_phase} /* Sources */ = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for build_id, _ref in source_builds:
        w(f"\t\t\t\t{build_id},")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")
    w("")

    header_paths = (
        "$(SRCROOT)/Vendor/opus",
        "$(SRCROOT)/Vendor/opus/include",
        "$(SRCROOT)/Vendor/opus/celt",
        "$(SRCROOT)/Vendor/opus/silk",
        "$(SRCROOT)/Vendor/opus/silk/float",
        "$(SRCROOT)/Vendor/opus/src",
        "$(SRCROOT)/Vendor/opus-bridge",
    )

    def settings_block(pairs: list[tuple[str, object]], indent: str = "\t\t\t") -> None:
        w(f"{indent}buildSettings = {{")
        for key, value in pairs:
            if isinstance(value, tuple):
                w(f"{indent}\t{key} = (")
                for item in value:
                    w(f"{indent}\t\t{q(str(item))},")
                w(f"{indent}\t);")
            else:
                w(f"{indent}\t{key} = {q(str(value))};")
        w(f"{indent}}};")

    common_target = [
        ("ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES", "YES"),
        ("ARCHS", "arm64"),
        ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
        ("CLANG_ENABLE_MODULES", "YES"),
        ("CLANG_ENABLE_OBJC_ARC", "YES"),
        ("CODE_SIGN_ENTITLEMENTS", "RoomCastGo/RoomCastGo.entitlements"),
        ("CODE_SIGN_IDENTITY", "Apple Development"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("DEVELOPMENT_TEAM", ""),
        ("ENABLE_PREVIEWS", "YES"),
        ("ENABLE_USER_SCRIPT_SANDBOXING", "NO"),
        ("FRAMEWORK_SEARCH_PATHS", ("$(SRCROOT)/build",)),
        ("GCC_WARN_INHIBIT_ALL_WARNINGS", "YES"),
        ("GENERATE_INFOPLIST_FILE", "NO"),
        ("HEADER_SEARCH_PATHS", header_paths),
        ("INFOPLIST_FILE", "RoomCastGo/Info.plist"),
        ("IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
        ("LD_RUNPATH_SEARCH_PATHS", ("$(inherited)", "@executable_path/Frameworks")),
        ("MARKETING_VERSION", "0.1.0"),
        ("OTHER_CFLAGS", ("-DHAVE_CONFIG_H", "-w")),
        ("PRODUCT_BUNDLE_IDENTIFIER", "channel.roomcast.go"),
        ("PRODUCT_NAME", "$(TARGET_NAME)"),
        ("SDKROOT", "iphoneos"),
        ("SUPPORTED_PLATFORMS", "iphoneos"),
        ("SUPPORTS_MACCATALYST", "NO"),
        ("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", "NO"),
        ("SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD", "NO"),
        ("SWIFT_OBJC_BRIDGING_HEADER", "RoomCastGo/RoomCastGo-Bridging-Header.h"),
        ("SWIFT_VERSION", "5.0"),
        ("TARGETED_DEVICE_FAMILY", "1"),
    ]
    debug_target = common_target + [
        ("DEBUG_INFORMATION_FORMAT", "dwarf"),
        ("ENABLE_TESTABILITY", "YES"),
        ("GCC_OPTIMIZATION_LEVEL", "0"),
        ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
        ("ONLY_ACTIVE_ARCH", "YES"),
        ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
        ("SWIFT_OPTIMIZATION_LEVEL", "-Onone"),
    ]
    release_target = common_target + [
        ("DEBUG_INFORMATION_FORMAT", "dwarf-with-dsym"),
        ("GCC_OPTIMIZATION_LEVEL", "s"),
        ("SWIFT_COMPILATION_MODE", "wholemodule"),
        ("SWIFT_OPTIMIZATION_LEVEL", "-O"),
        ("VALIDATE_PRODUCT", "YES"),
    ]
    common_project = [
        ("ALWAYS_SEARCH_USER_PATHS", "NO"),
        ("CLANG_ANALYZER_NONNULL", "YES"),
        ("CLANG_ENABLE_MODULES", "YES"),
        ("CLANG_ENABLE_OBJC_ARC", "YES"),
        ("CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING", "YES"),
        ("CLANG_WARN_BOOL_CONVERSION", "YES"),
        ("CLANG_WARN_COMMA", "YES"),
        ("CLANG_WARN_CONSTANT_CONVERSION", "YES"),
        ("CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS", "YES"),
        ("CLANG_WARN_EMPTY_BODY", "YES"),
        ("CLANG_WARN_ENUM_CONVERSION", "YES"),
        ("CLANG_WARN_INFINITE_RECURSION", "YES"),
        ("CLANG_WARN_INT_CONVERSION", "YES"),
        ("CLANG_WARN_NON_LITERAL_NULL_CONVERSION", "YES"),
        ("CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF", "YES"),
        ("CLANG_WARN_OBJC_LITERAL_CONVERSION", "YES"),
        ("CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER", "YES"),
        ("CLANG_WARN_RANGE_LOOP_ANALYSIS", "YES"),
        ("CLANG_WARN_STRICT_PROTOTYPES", "YES"),
        ("CLANG_WARN_SUSPICIOUS_MOVE", "YES"),
        ("CLANG_WARN_UNREACHABLE_CODE", "YES"),
        ("COPY_PHASE_STRIP", "NO"),
        ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
        ("GCC_C_LANGUAGE_STANDARD", "c99"),
        ("GCC_NO_COMMON_BLOCKS", "YES"),
        ("GCC_WARN_64_TO_32_BIT_CONVERSION", "YES"),
        ("GCC_WARN_ABOUT_RETURN_TYPE", "YES"),
        ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
        ("GCC_WARN_UNINITIALIZED_AUTOS", "YES"),
        ("GCC_WARN_UNUSED_FUNCTION", "YES"),
        ("GCC_WARN_UNUSED_VARIABLE", "YES"),
        ("IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
        ("SDKROOT", "iphoneos"),
        ("TARGETED_DEVICE_FAMILY", "1"),
    ]

    w("/* Begin XCBuildConfiguration section */")
    for config_id, name, pairs in (
        (target_debug, "Debug", debug_target),
        (target_release, "Release", release_target),
        (project_debug, "Debug", common_project + [("DEBUG_INFORMATION_FORMAT", "dwarf"), ("ENABLE_TESTABILITY", "YES"), ("GCC_OPTIMIZATION_LEVEL", "0"), ("ONLY_ACTIVE_ARCH", "YES"), ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"), ("SWIFT_OPTIMIZATION_LEVEL", "-Onone")]),
        (project_release, "Release", common_project + [("DEBUG_INFORMATION_FORMAT", "dwarf-with-dsym"), ("ENABLE_NS_ASSERTIONS", "NO"), ("SWIFT_COMPILATION_MODE", "wholemodule"), ("SWIFT_OPTIMIZATION_LEVEL", "-O"), ("VALIDATE_PRODUCT", "YES")]),
    ):
        w(f"\t\t{config_id} /* {name} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        settings_block(pairs)
        w(f"\t\t\tname = {name};")
        w("\t\t};")
    w("/* End XCBuildConfiguration section */")
    w("")
    w("/* Begin XCConfigurationList section */")
    w(f"\t\t{project_list} /* Build configuration list for PBXProject */ = {{")
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w(f"\t\t\t\t{project_debug},")
    w(f"\t\t\t\t{project_release},")
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")
    w(f"\t\t{target_list} /* Build configuration list for PBXNativeTarget */ = {{")
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w(f"\t\t\t\t{target_debug},")
    w(f"\t\t\t\t{target_release},")
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")
    w("/* End XCConfigurationList section */")
    w("\t};")
    w(f"\trootObject = {project};")
    w("}")
    w("")

    pbx = PROJECT / "project.pbxproj"
    PROJECT.mkdir(parents=True, exist_ok=True)
    pbx.write_text("\n".join(lines), encoding="utf-8")

    scheme_dir = PROJECT / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "RoomCastGo.app"
               BlueprintName = "RoomCastGo"
               ReferencedContainer = "container:RoomCastGo.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "RoomCastGo.app"
            BlueprintName = "RoomCastGo"
            ReferencedContainer = "container:RoomCastGo.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "RoomCastGo.app"
            BlueprintName = "RoomCastGo"
            ReferencedContainer = "container:RoomCastGo.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    (scheme_dir / "RoomCastGo.xcscheme").write_text(scheme, encoding="utf-8")
    print(f"wrote {pbx} ({len(sources)} sources)")


if __name__ == "__main__":
    main()
