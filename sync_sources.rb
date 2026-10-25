#!/usr/bin/env ruby
# Sync FinalMusic/*.swift into FinalMusic.xcodeproj (add new files, drop deleted ones).
# Run after adding or removing a source file: ruby sync_sources.rb
require 'xcodeproj'

root = File.expand_path(__dir__)
proj_path = File.join(root, 'FinalMusic.xcodeproj')
proj = Xcodeproj::Project.open(proj_path)
target = proj.targets.find { |t| t.name == 'FinalMusic' } or abort 'no FinalMusic target'

group = proj.main_group.groups.find { |g| g.display_name == 'FinalMusic' } ||
        proj.new_group('FinalMusic', 'FinalMusic')

on_disk = Dir.glob(File.join(root, 'FinalMusic', '*.swift')).sort
existing = {}
group.files.each { |f| existing[File.expand_path(f.real_path.to_s)] = f if f.path.to_s.end_with?('.swift') }

added = []
on_disk.each do |path|
  next if existing.key?(path)
  ref = group.new_reference(path)
  target.source_build_phase.add_file_reference(ref)
  added << File.basename(path)
end

removed = []
existing.each do |path, ref|
  next if on_disk.include?(path)
  target.source_build_phase.files.select { |bf| bf.file_ref == ref }.each(&:remove_from_project)
  ref.remove_from_project
  removed << File.basename(path)
end

# Asset catalog (app icon): keep it referenced in the Resources phase so
# actool compiles AppIcon into the bundle.
assets = File.join(root, 'FinalMusic', 'Assets.xcassets')
if File.directory?(assets)
  already = group.files.any? { |f| File.expand_path(f.real_path.to_s) == assets }
  unless already
    ref = group.new_reference(assets)
    target.resources_build_phase.add_file_reference(ref)
    puts 'assets: Assets.xcassets wired into Resources'
  end
end

proj.save
puts "added: #{added.empty? ? 'none' : added.join(', ')}"
puts "removed: #{removed.empty? ? 'none' : removed.join(', ')}"
puts "sources now: #{target.source_build_phase.files.count}"
