//go:build !darwin

package sanitize

// TunName — имя сетевого адаптера. Задаётся службой, а не приложением: иначе можно было бы
// открыть по имени адаптер Wintun другой программы.
const TunName = "AstatVPN"
