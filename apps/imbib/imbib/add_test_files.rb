#!/usr/bin/env ruby
require 'xcodeproj'

project_path = '/Users/tabel/Projects/imbib/imbib/imbib.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Find the imbibUITests target
ui_tests_target = project.targets.find { |t| t.name == 'imbibUITests' }

unless ui_tests_target
  puts "Error: Could not find imbibUITests target"
  exit 1
end

# Find the imbibUITests group
ui_tests_group = project.main_group.find_subpath('imbibUITests', false)

unless ui_tests_group
  puts "Error: Could not find imbibUITests group"
  exit 1
end

# Remove and recreate children to start fresh (but keep imbibUITests.swift)
main_file_ref = ui_tests_group.files.find { |f| f.path == 'imbibUITests.swift' }

# Define the directory structure
directories = {
  'Infrastructure' => [
    'AccessibilityIdentifiers.swift',
    'TestApp.swift',
    'TestDataFactory.swift'
  ],
  'Pages' => [
    'DetailViewPage.swift',
    'PDFViewerPage.swift',
    'PublicationListPage.swift',
    'SearchPalettePage.swift',
    'SettingsPage.swift',
    'SidebarPage.swift'
  ],
  'Workflows' => [
    'ExportWorkflowTests.swift',
    'ImportWorkflowTests.swift',
    'OrganizationWorkflowTests.swift',
    'SearchWorkflowTests.swift',
    'TriageWorkflowTests.swift'
  ],
  'Components' => [
    'DetailPanelTests.swift',
    'GlobalSearchTests.swift',
    'KeyboardShortcutsTests.swift',
    'PublicationListTests.swift',
    'SidebarTests.swift',
    'ToolbarTests.swift'
  ],
  'Accessibility' => [
    'AccessibilityAuditTests.swift',
    'KeyboardNavigationTests.swift',
    'VoiceOverTests.swift'
  ],
  'Integration' => [
    'ADSIntegrationTests.swift',
    'ArXivIntegrationTests.swift',
    'CrossrefIntegrationTests.swift'
  ]
}

# Also add the Info.plist
info_plist_ref = ui_tests_group.new_file('Info.plist')

# Add directories and files
directories.each do |dir_name, files|
  # Create or find the subgroup
  subgroup = ui_tests_group.find_subpath(dir_name, false) || ui_tests_group.new_group(dir_name, dir_name)

  files.each do |file_name|
    file_path = "#{dir_name}/#{file_name}"

    # Check if file already exists in group
    existing = subgroup.files.find { |f| f.path == file_name }
    next if existing

    # Add the file reference
    file_ref = subgroup.new_file(file_name)

    # Add to compile sources
    ui_tests_target.source_build_phase.add_file_reference(file_ref)

    puts "Added: #{file_path}"
  end
end

# Also add Snapshots group (empty for now)
snapshots_group = ui_tests_group.find_subpath('Snapshots', false) || ui_tests_group.new_group('Snapshots', 'Snapshots')

project.save

puts "\nProject saved successfully!"
puts "Total files in imbibUITests: #{ui_tests_group.recursive_children.select { |c| c.is_a?(Xcodeproj::Project::Object::PBXFileReference) }.count}"
