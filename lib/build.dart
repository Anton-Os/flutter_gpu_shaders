library flutter_gpu_shaders;

import 'dart:convert' as convert;
import 'dart:io';

import 'package:native_assets_cli/native_assets_cli.dart';

import 'package:flutter_gpu_shaders/environment.dart';

/// Loads a shader bundle manifest file and builds a shader bundle.
Future<void> _buildShaderBundleJson({
  required Uri packageRoot,
  required Uri inputManifestFilePath,
  required Uri outputBundleFilePath,
}) async {
  /////////////////////////////////////////////////////////////////////////////
  /// 1. Parse the manifest file.
  ///

  final manifest =
      await File(inputManifestFilePath.toFilePath()).readAsString();
  final decodedManifest = convert.json.decode(manifest);
  String reconstitutedManifest = convert.json.encode(decodedManifest);

  //throw Exception(reconstitutedManifest);

  /////////////////////////////////////////////////////////////////////////////
  /// 2. Build the shader bundle.
  ///

  final impellercExec = await findImpellerC();
  final shaderLibPath = impellercExec.resolve('./shader_lib');
  final impellercArgs = [
    '--sl=${outputBundleFilePath.toFilePath()}',
    '--shader-bundle=$reconstitutedManifest',
    '--include=${inputManifestFilePath.resolve('./').toFilePath()}',
    '--include=${shaderLibPath.toFilePath()}',
  ];

  final impellerc = Process.runSync(impellercExec.toFilePath(), impellercArgs,
      workingDirectory: packageRoot.toFilePath());
  if (impellerc.exitCode != 0) {
    throw Exception(
        'Failed to build shader bundle: ${impellerc.stderr}\n${impellerc.stdout}');
  }
}

/// Build a Flutter GPU shader bundle/library from a JSON manifest file.
///
/// The [buildConfig] and [buildOutput] are provided by the build hook system.
///
/// The [manifestFileName] is the path to the JSON manifest file, which is
/// relative to the package root where the build hook resides.
///
/// The [manifestFileName] must end with ".shaderbundle.json".
///
/// The built shader bundle will be written to
/// `build/shaderbundles/[name].shaderbundle`,
/// relative to the package root where the build hook resides.
///
/// Example usage:
///
/// hook/build.dart
/// ```dart
/// void main(List<String> args) async {
///   await build(args, (config, output) async {
///     await buildShaderBundleJson(
///         buildConfig: config,
///         buildOutput: output,
///         manifestFileName: 'my_cool_bundle.shaderbundle.json');
///   });
/// }
/// ```
///
/// my_cool_bundle.shaderbundle.json
/// ```json
/// {
///     "SimpleVertex": {
///         "type": "vertex",
///         "file": "shaders/my_cool_shader.vert"
///     }
/// }
/// ```
///

Future<String> genShaderSrc(BuildConfig config, String filePath) async {
  Uri shaderFilePath = config.packageRoot.resolve(filePath);
  File shaderFile = File(shaderFilePath.path);

  String shaderContents = "";
  await shaderFile.readAsString().then((String contents) async {
    int startOffset = 0, includeOffset = 0;

    while(contents.contains("#include")){
      startOffset = contents.indexOf("#include");
      includeOffset = startOffset + 10;

      String includeStr = "";
      while(contents[includeOffset] != "\n"){
        if(contents[includeOffset] != "\\" && contents[includeOffset] != ">" && contents[includeOffset] != ";")
          includeStr = includeStr + contents[includeOffset];
        includeOffset++;
      }
      print("Include Str is $includeStr");

      String includeSrc = ""; // TODO: Populate this string
      if(includeStr.contains(".glsl")){
        String includeFilePath = includeStr.split("/").last.trim().replaceAll("\"", "");
        includeFilePath = filePath.substring(0, filePath.lastIndexOf('/') + 1) + includeFilePath;
        print("New include file path is $includeFilePath");
        File includeFile = File(includeFilePath);
        await includeFile.readAsString().then((String includeContents){ includeSrc = includeContents; });
      }

      contents = contents.replaceAll("#include", includeSrc);
    }

    shaderContents = contents;
    print("Shader contents are $shaderContents");
  });

  // final outDir = Directory.fromUri(config.packageRoot.resolve('build/shaderbundles/'));
  // File(outDir.path + filePath.split('/').last).create();

  return shaderContents;
}

Future<void> buildShaderBundleJson(
    {required BuildConfig buildConfig,
    required BuildOutputBuilder buildOutput,
    required String manifestFileName}) async {
  final outDir = Directory.fromUri(buildConfig.packageRoot.resolve('build/shaderbundles/'));
  await outDir.create(recursive: true);

  Uri manifestFilePath = buildConfig.packageRoot.resolve(manifestFileName);
  File manifestFile = File(manifestFilePath.path);
  print("Manifest file path is ${manifestFilePath.path}");
  File manifestOutFile = await File(outDir.path + manifestFilePath.path.split('/').last).create();

  manifestFile.readAsString().then((String contents) {
    String manifestOutContents = contents;
    manifestOutFile.writeAsString(manifestOutContents);

    contents.split('\n').forEach((lineStr){
      if(lineStr.contains("glsl")){
        int startIdx = lineStr.indexOf("file:") + 9; // starts after "...
        String shaderFilePath = "";
        while(lineStr[startIdx] != "\n" && startIdx < lineStr.length - 1) {
          if (lineStr[startIdx] != "\"") shaderFilePath = shaderFilePath + lineStr[startIdx];
          startIdx++;
        }
        if(shaderFilePath.isNotEmpty) {
          <String>["%20", " ", "e:"].forEach((entry){ shaderFilePath = shaderFilePath.replaceAll(entry, ''); });
          shaderFilePath = manifestFilePath.path.substring(0, manifestFile.path.indexOf("lib/")) + shaderFilePath;
          print("Shader file path is $shaderFilePath, subpath is ${shaderFilePath.substring(shaderFilePath.indexOf("lib/"))}");
          genShaderSrc(buildConfig, shaderFilePath).then((shaderContent) async {
            File shaderOutFile = await File(outDir.path + shaderFilePath.split('/').last).create();
            shaderOutFile.writeAsString(shaderContent);
            await manifestOutFile.readAsString().then((manifestContents){
              manifestOutContents = manifestContents.replaceAll(
                  shaderFilePath.substring(shaderFilePath.indexOf("lib/")),
                  shaderOutFile.path.substring(shaderOutFile.path.indexOf("build/"))
              );
              manifestOutFile.writeAsString(manifestOutContents);
              contents = manifestOutContents; // Updating to latest
            });
          });
        }
      }
    });
  });

  String outputFileName = Uri(path: manifestFileName).pathSegments.last;
  if (!outputFileName.endsWith('.shaderbundle.json')) {
    throw Exception(
        'Shader bundle manifest file names must end with ".shaderbundle.json".');
  }
  if (outputFileName.length <= '.shaderbundle.json'.length) {
    throw Exception(
        'Invalid shader bundle manifest file name: $outputFileName');
  }
  if (outputFileName.endsWith('.json')) {
    outputFileName = outputFileName.substring(0, outputFileName.length - 5);
  }

  // TODO(bdero): Register DataAssets instead of outputting to the project directory once it's possible to do so.
  //final outDir = config.outputDirectory;
  final packageRoot = buildConfig.packageRoot;

  final inFile = packageRoot.resolve(manifestFileName);
  final outFile = outDir.uri.resolve(outputFileName);

  await _buildShaderBundleJson(
      packageRoot: packageRoot,
      inputManifestFilePath: inFile,
      outputBundleFilePath: outFile);
}
