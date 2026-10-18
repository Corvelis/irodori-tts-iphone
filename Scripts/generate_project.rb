#!/usr/bin/env ruby
require 'xcodeproj'
require 'pathname'
require 'fileutils'

root = Pathname.new(__dir__).parent
force = ARGV.delete('--force')
abort 'Usage: ruby Scripts/generate_project.rb [--force]' unless ARGV.empty?
version = root.join('VERSION').read.strip
abort 'VERSION must contain a numeric app version' unless version.match?(/\A\d+\.\d+\.\d+\z/)
paths = %w[IrodoriSamples IrodoriComparison].map { |name| root.join("Examples/#{name}.xcodeproj") }
abort 'Generated projects exist; pass --force to regenerate both.' if !force && paths.any?(&:exist?)

paths.each do |path|
  comparison = path.basename.to_s.start_with?('IrodoriComparison')
  FileUtils.rm_rf(path) if force
  project = Xcodeproj::Project.new(path.to_s)
  group = project.main_group.new_group('Shared', 'Shared')
  refs = root.join('Examples/Shared').glob('*.swift').sort.map { |file| group.new_file(file.basename.to_s) }
  assets = group.new_file('Assets.xcassets')
  package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  package.relative_path = '..'
  project.root_object.package_references << package
  speech_package = nil
  if comparison
    speech_package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
    speech_package.relative_path = '../Packages/IrodoriSpeechCpp'
    project.root_object.package_references << speech_package
  end
  schemes = []
  platforms = comparison ? [['IrodoriiOS', :ios, '17.0']] : [['IrodoriiOS', :ios, '17.0'], ['IrodoriMac', :osx, '14.0']]
  platforms.each do |name, platform, deployment|
    target = project.new_target(:application, name, platform, deployment)
    target.add_file_references(refs)
    target.resources_build_phase.add_file_reference(assets, true)
    products = [[package, 'IrodoriTTS']]
    products << [speech_package, 'IrodoriSpeechCpp'] if comparison
    products.each do |dependency, product_name|
      product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
      product.package = dependency
      product.product_name = product_name
      target.package_product_dependencies << product
      build = project.new(Xcodeproj::Project::Object::PBXBuildFile)
      build.product_ref = product
      target.frameworks_build_phase.files << build
    end
    if comparison
      diagnostics = project.main_group.new_group('Diagnostics', 'Diagnostics')
      target.add_file_references([diagnostics.new_file('ComparisonSmoke.swift')])
      project.add_build_configuration('Diagnostics', :release)
      target.add_build_configuration('Diagnostics', :release)
    end
    target.build_configurations.each do |config|
      s = config.build_settings
      flavor = comparison ? 'comparison' : 'coreml'
      s['PRODUCT_BUNDLE_IDENTIFIER'] = "org.example.irodori.#{flavor}.#{platform}"
      s['SWIFT_VERSION'] = '5.0'
      s['ASSETCATALOG_COMPILER_APPICON_NAME'] = platform == :ios ? 'AppIcon-iOS' : 'AppIcon-macOS'
      s['GENERATE_INFOPLIST_FILE'] = 'YES'
      s['INFOPLIST_KEY_NSMicrophoneUsageDescription'] = comparison ? '音声認識のお試しと、参照音声として自分の声を録音します。' : '参照音声として自分の声を録音します。'
      s['INFOPLIST_KEY_CFBundleDisplayName'] = 'Irodori TTS'
      s['CODE_SIGN_STYLE'] = 'Automatic'
      s['MARKETING_VERSION'] = version
      s['CURRENT_PROJECT_VERSION'] = '3'
      if config.name == 'Diagnostics'
        s['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) IRODORI_SAMPLE_DIAGNOSTICS'
        s['SWIFT_OPTIMIZATION_LEVEL'] = '-O'
      end
      if platform == :ios
        s['TARGETED_DEVICE_FAMILY'] = '1,2'
        s['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'x86_64'
        s['INFOPLIST_FILE'] = 'iOS/Info.plist'
        s['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
        s['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
      else
        s['CODE_SIGN_ENTITLEMENTS'] = 'macOS/IrodoriMac.entitlements'
        s['ENABLE_HARDENED_RUNTIME'] = 'YES'
      end
    end
    schemes << [target, name]
    schemes << [target, name + '-Diagnostics'] if comparison
  end
  project.predictabilize_uuids
  schemes.each do |target, scheme_name|
    scheme = Xcodeproj::XCScheme.new
    scheme.add_build_target(target)
    scheme.set_launch_target(target)
    if scheme_name.end_with?('-Diagnostics')
      scheme.launch_action.build_configuration = 'Diagnostics'
      scheme.profile_action.build_configuration = 'Diagnostics'
    end
    scheme.save_as(path, scheme_name, true)
  end
  project.save
  puts path
end
