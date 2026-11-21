# Adds the FollowActivity widget extension (the followed train's Live Activity) to Runner.xcodeproj.
# Idempotent: run again and nothing changes. Usage: ruby tools/ios/add_follow_activity_target.rb
require 'xcodeproj'

APP = File.expand_path('../..', __dir__)
project = Xcodeproj::Project.open(File.join(APP, 'ios/Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' }
NAME = 'FollowActivity'

if project.targets.any? { |t| t.name == NAME }
  puts "#{NAME} already there"
  exit 0
end

ext = project.new_target(:app_extension, NAME, :ios, '16.1')
# new_target links Foundation by a path inside one SDK version (e.g. iPhoneOS18.0.sdk), which
# breaks on other Xcodes; it is linked implicitly anyway.
ext.frameworks_build_phase.files.select { |f| f.display_name == 'Foundation.framework' }.each do |f|
  ref = f.file_ref
  f.remove_from_project
  ref.remove_from_project if ref && ref.build_files.empty?
end
generated = project.files.find { |f| f.path == 'Flutter/Generated.xcconfig' } or abort 'Generated.xcconfig not found'

# Flutter builds Debug, Release and Profile: the extension needs all three.
unless ext.build_configurations.any? { |c| c.name == 'Profile' }
  release = ext.build_configurations.find { |c| c.name == 'Release' }
  profile = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  profile.name = 'Profile'
  profile.build_settings = release.build_settings.dup
  ext.build_configuration_list.build_configurations << profile
end

ext.build_configurations.each do |c|
  c.base_configuration_reference = generated # FLUTTER_BUILD_NAME / NUMBER: same version as the app
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.jfcaba.proximotren.FollowActivity'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = 'FollowActivity/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['SWIFT_VERSION'] = '5.0'
  s['DEVELOPMENT_TEAM'] = 'JH8NFJ6XW7'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['TARGETED_DEVICE_FAMILY'] = '1'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '16.1'
  s['SKIP_INSTALL'] = 'YES'
  s['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
  s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  s['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
end

group = project.main_group.find_subpath(NAME, true)
group.set_source_tree('<group>')
group.set_path(NAME)
%w[FollowActivityBundle.swift FollowActivityLiveActivity.swift].each do |f|
  ext.source_build_phase.add_file_reference(group.new_reference(f))
end
group.new_reference('Info.plist')

# The attributes are compiled into both the app and the extension.
runner_group = project.main_group.find_subpath('Runner', false)
shared = runner_group.files.find { |f| f.path == 'TrainActivityAttributes.swift' } || runner_group.new_reference('TrainActivityAttributes.swift')
runner.source_build_phase.add_file_reference(shared, true)
ext.source_build_phase.add_file_reference(shared, true)

%w[WidgetKit SwiftUI].each do |fw|
  ref = project.frameworks_group.new_file("System/Library/Frameworks/#{fw}.framework", :sdk_root)
  ext.frameworks_build_phase.add_file_reference(ref, true)
end

# Push for following (aps-environment), like the app's Runner.entitlements.
runner.build_configurations.each { |c| c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements' }
unless runner_group.files.any? { |f| f.path == 'Runner.entitlements' }
  runner_group.new_reference('Runner.entitlements')
end

runner.add_dependency(ext)
embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
build_file = embed.add_file_reference(ext.product_reference, true)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
# Before Flutter's script phases ("Thin Binary"), or Xcode reports a dependency cycle.
phases = runner.build_phases
phases.delete(embed)
idx = phases.index { |p| p.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) && p.name.to_s.include?('Thin Binary') } || phases.length
phases.insert(idx, embed)

project.save
puts "added #{NAME}"
