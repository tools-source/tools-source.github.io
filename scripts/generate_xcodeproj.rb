#!/usr/bin/env ruby

require 'rubygems'
require 'fileutils'
require 'pathname'
require 'xcodeproj'

PROJECT_NAME = 'MusicTube'
ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, "#{PROJECT_NAME}.xcodeproj")
INFO_PLIST_PATH = File.join(PROJECT_NAME, 'Resources', 'Info.plist')
ENTITLEMENTS_PATH = File.join(PROJECT_NAME, 'Resources', 'MusicTube.entitlements')
SIMULATOR_ENTITLEMENTS_PATH = File.join(PROJECT_NAME, 'Resources', 'MusicTubeSimulator.entitlements')
XCCONFIG_PATH = File.join(PROJECT_NAME, 'Resources', 'Secrets.xcconfig')
VENDOR_ROOT = File.join(ROOT, PROJECT_NAME, 'Vendor', 'YouTubeKit')
VENDOR_RESOURCE_ROOT = File.join(VENDOR_ROOT, 'Resources')

SOURCE_FOLDERS = {
  'App' => %w[
    AppState.swift
    MusicTubeApp.swift
  ],
  'CarPlay' => %w[
    CarPlayManager.swift
    CarPlaySceneDelegate.swift
  ],
  'Models' => %w[
    Track.swift
    YouTubeUser.swift
  ],
  'Services' => %w[
    PlaybackService.swift
    ServiceProtocols.swift
    YouTubeAPIService.swift
    YouTubeAuthService.swift
  ],
  'Views' => %w[
    HomeView.swift
    LibraryView.swift
    LoginView.swift
    PlayerView.swift
    RootView.swift
    SearchView.swift
  ],
  'Views/Components' => %w[
    AsyncArtworkView.swift
    TrackRowView.swift
    YouTubeEmbedView.swift
  ]
}.freeze

def add_swift_files(root_group, target)
  SOURCE_FOLDERS.each do |folder_path, file_names|
    folder_group = ensure_group(root_group, folder_path)

    file_names.each do |file_name|
      file_ref = folder_group.new_file(file_name)
      target.add_file_references([file_ref])
    end
  end
end

def add_vendor_files(root_group, target)
  vendor_group = ensure_group(root_group, 'Vendor/YouTubeKit')

  Dir.glob(File.join(VENDOR_ROOT, '**', '*.swift')).sort.each do |absolute_path|
    relative_dir = Pathname(File.dirname(absolute_path)).relative_path_from(Pathname(VENDOR_ROOT)).to_s
    folder_group = relative_dir == '.' ? vendor_group : ensure_group(vendor_group, relative_dir)
    file_ref = folder_group.new_file(File.basename(absolute_path))
    target.add_file_references([file_ref])
  end
end

def add_vendor_resources(root_group, target)
  resources_group = ensure_group(root_group, 'Vendor/YouTubeKit/Resources')

  Dir.glob(File.join(VENDOR_RESOURCE_ROOT, '*')).sort.each do |absolute_path|
    next unless File.file?(absolute_path)

    file_ref = resources_group.new_file(File.basename(absolute_path))
    target.resources_build_phase.add_file_reference(file_ref, true)
  end
end

def ensure_group(root_group, relative_path)
  relative_path.split('/').reduce(root_group) do |group, component|
    group.groups.find { |child| child.path == component || child.display_name == component } ||
      group.new_group(component, component)
  end
end

FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2600'
project.root_object.attributes['LastUpgradeCheck'] = '2600'
project.root_object.development_region = 'en'

music_group = project.main_group.new_group(PROJECT_NAME, PROJECT_NAME)
music_group.set_source_tree('SOURCE_ROOT')

resources_group = ensure_group(music_group, 'Resources')

target = project.new_target(:application, PROJECT_NAME, :ios, '17.0')
target.product_name = PROJECT_NAME

add_swift_files(music_group, target)
add_vendor_files(music_group, target)

assets_ref = resources_group.new_file('Assets.xcassets')
launch_ref = resources_group.new_file('LaunchScreen.storyboard')
info_ref = resources_group.new_file('Info.plist')
entitlements_ref = resources_group.new_file('MusicTube.entitlements')
simulator_entitlements_ref = resources_group.new_file('MusicTubeSimulator.entitlements')
secrets_ref = resources_group.new_file('Secrets.xcconfig')

target.resources_build_phase.add_file_reference(assets_ref, true)
target.resources_build_phase.add_file_reference(launch_ref, true)
add_vendor_resources(music_group, target)

project.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = ''
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
end

target.build_configurations.each do |config|
  config.base_configuration_reference = secrets_ref

  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
  config.build_settings['APPLICATION_SCENE_MANIFEST_GENERATION'] = 'NO'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = ENTITLEMENTS_PATH
  config.build_settings['CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]'] = SIMULATOR_ENTITLEMENTS_PATH
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['DEVELOPMENT_TEAM'] = ''
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['INFOPLIST_FILE'] = INFO_PLIST_PATH
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks']
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.codex.MusicTube'
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  config.build_settings['SDKROOT'] = 'iphoneos'
  config.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
  config.build_settings['SUPPORTS_MACCATALYST'] = 'NO'
  config.build_settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
end

workspace_dir = File.join(PROJECT_PATH, 'project.xcworkspace')
FileUtils.mkdir_p(workspace_dir)
File.write(
  File.join(workspace_dir, 'contents.xcworkspacedata'),
  <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <Workspace
       version = "1.0">
       <FileRef
          location = "self:">
       </FileRef>
    </Workspace>
  XML
)

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(PROJECT_PATH, PROJECT_NAME, true)

project.save

puts "Generated #{PROJECT_PATH}"
