# Adds the next-trains home screen widget (view and data files) to the FollowActivity extension and gives the extension
# its App Group entitlements. Idempotent. Usage: ruby tools/ios/add_next_trains_widget.rb
require 'xcodeproj'

APP = File.expand_path('../..', __dir__)
project = Xcodeproj::Project.open(File.join(APP, 'ios/Runner.xcodeproj'))
ext = project.targets.find { |t| t.name == 'FollowActivity' } or abort 'FollowActivity target missing'
group = project.main_group.find_subpath('FollowActivity', false) or abort 'FollowActivity group missing'

%w[NextTrainsWidget.swift NextTrainsData.swift].each do |name|
  next if ext.source_build_phase.files.any? { |f| f.display_name == name }
  ref = group.files.find { |f| f.path == name } || group.new_reference(name)
  ext.source_build_phase.add_file_reference(ref, true)
end
group.new_reference('FollowActivity.entitlements') unless group.files.any? { |f| f.path == 'FollowActivity.entitlements' }
ext.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'FollowActivity/FollowActivity.entitlements'
end
project.save
puts 'ok'
