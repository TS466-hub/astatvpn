//go:build darwin

package sanitize

// TunName — имя сетевого интерфейса. На macOS оно обязано иметь вид utunN. Задаётся службой, а не
// приложением. Номер взят с запасом: первые utun занимает сама система и другие программы.
const TunName = "utun223"
