# Добавляет в проект Xcode расширение системного VPN (цель Tunnel) и общий код из apple/.
# Запускается один раз для каждой системы, результат (project.pbxproj) хранится в git:
#   GEM_HOME=$(ls -d /opt/homebrew/Cellar/cocoapods/*/libexec) /opt/homebrew/opt/ruby/bin/ruby tool/apple_add_tunnel.rb ios
#   ... tool/apple_add_tunnel.rb macos
# Нужен, только если каталог ios/ или macos/ создан заново командой flutter create.
require 'xcodeproj'

platform = ARGV[0]
abort 'Укажите систему: ios или macos' unless %w[ios macos].include?(platform)
ios = platform == 'ios'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, platform, 'Runner.xcodeproj'))
abort 'Цель Tunnel уже есть в проекте' if project.targets.any? { |t| t.name == 'Tunnel' }
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'Нет цели Runner'

bundle_id = 'shop.autohitech.astatvpn'
# на iOS группа приложений начинается с group., на macOS — с идентификатора команды
app_group = ios ? "group.#{bundle_id}" : "$(DEVELOPMENT_TEAM).#{bundle_id}"

# общий код и ядро лежат рядом с проектом, в apple/
group = project.main_group.new_group('Apple', '../apple')
shared = group.new_file('Shared/Shared.swift')
channel = group.new_file('Runner/VpnChannel.swift')
provider = group.new_file('Tunnel/PacketTunnelProvider.swift')
group.new_file('Tunnel/Info.plist')
group.new_file("Tunnel/Tunnel#{ios ? 'IOS' : 'MacOS'}.entitlements")
core = group.new_file('LibXray.xcframework')
geo = %w[geo/geoip.dat geo/geosite.dat].map { |f| group.new_file(f) }

tunnel = project.new_target(:app_extension, 'Tunnel', ios ? :ios : :osx, ios ? '15.0' : '12.0', nil, :swift)
tunnel.add_file_references([shared, provider])
tunnel.add_resources(geo)
tunnel.frameworks_build_phase.add_file_reference(core)

# номер версии расширения должен совпадать с номером приложения: берём его из настроек Flutter
generated = project.files.find { |f| f.path.to_s.end_with?(ios ? 'Generated.xcconfig' : 'Flutter-Generated.xcconfig') }
tunnel.build_configurations.each do |config|
  config.base_configuration_reference = generated
  s = config.build_settings
  s['PRODUCT_NAME'] = 'Tunnel'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{bundle_id}.tunnel"
  s['INFOPLIST_FILE'] = '../apple/Tunnel/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = "../apple/Tunnel/Tunnel#{ios ? 'IOS' : 'MacOS'}.entitlements"
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['ASTAT_APP_GROUP'] = app_group
  s['SWIFT_VERSION'] = '5.0'
  s['SKIP_INSTALL'] = 'YES'
  s['OTHER_LDFLAGS'] = ['$(inherited)', '-lresolv']
  s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
  s['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
  if ios
    s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    s['TARGETED_DEVICE_FAMILY'] = '1,2'
  else
    s['MACOSX_DEPLOYMENT_TARGET'] = '12.0'
    s['ENABLE_HARDENED_RUNTIME'] = 'YES'
  end
end

# приложение: общий код, ядро (для замера задержки), права и вложенное расширение
runner.add_file_references([shared, channel])
runner.frameworks_build_phase.add_file_reference(core)
runner.build_configurations.each do |config|
  s = config.build_settings
  s['ASTAT_APP_GROUP'] = app_group
  s['OTHER_LDFLAGS'] = ['$(inherited)', '-lresolv']
  s['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements' if ios
end
if ios
  runner_group = project.main_group.children.find { |g| g.display_name == 'Runner' }
  runner_group.new_file('Runner.entitlements')
end

runner.add_dependency(tunnel)
embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
embed.dst_subfolder_spec = '13' # PlugIns
embed.dst_path = ''
embed.add_file_reference(tunnel.product_reference, true).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
# расширение вкладывается до завершающих скриптов Flutter, иначе Xcode сообщает о цикле сборки
thin = runner.build_phases.index { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
if thin
  runner.build_phases.delete(embed)
  runner.build_phases.insert(thin, embed)
end

project.save
puts "Готово: цель Tunnel добавлена в #{platform}/Runner.xcodeproj"
