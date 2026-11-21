# Добавляет в проект macOS шаг сборки, который кладёт службу и геобазы в Contents/Resources приложения.
# Запускается один раз, результат (project.pbxproj) хранится в git. Нужен, только если каталог macos/
# создан заново командой flutter create:
#   GEM_HOME=$(ls -d /opt/homebrew/Cellar/cocoapods/*/libexec) /opt/homebrew/opt/ruby/bin/ruby tool/macos_add_helper.rb
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'macos', 'Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'Нет цели Runner'
name = 'Служба AstatVPN'
abort 'Шаг уже есть в проекте' if runner.build_phases.any? { |p| p.respond_to?(:name) && p.name == name }

phase = runner.new_shell_script_build_phase(name)
phase.shell_path = '/bin/sh'
phase.always_out_of_date = '1'
phase.shell_script = <<~'SH'
  set -e
  SRC="$PROJECT_DIR/../build/core/macos"
  DST="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
  for f in astat-helper geoip.dat geosite.dat; do
    if [ ! -s "$SRC/$f" ]; then
      echo "error: нет файла build/core/macos/$f. Сначала выполните tool/build_core_macos.sh"
      exit 1
    fi
  done
  mkdir -p "$DST"
  cp "$SRC/astat-helper" "$SRC/geoip.dat" "$SRC/geosite.dat" "$DST/"
  chmod 755 "$DST/astat-helper"
SH

runner.build_configurations.each { |c| c.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO' }
project.save
puts 'Готово: шаг сборки добавлен в macos/Runner.xcodeproj'
