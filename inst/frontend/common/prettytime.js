import { getCurrentLanguage, t } from "./lang.js"

/**
 * A localized, unit-labelled rendering of a duration in nanoseconds, used
 * for the process status tab's "running for ..." display. The cell
 * run-time chip uses components/RunButton.js's format_runtime() instead,
 * which matches ui-3.md's "0.04 s" / "1 min 3 s" wording.
 */
export const prettytime = (time_ns) => {
    if (time_ns == null) {
        return "---"
    }

    const units = ["nanosecond", "microsecond", "millisecond", "second"]
    const units_latin = ["ns", "μs", "ms", "sec"]

    // Find the right prefix
    let result = time_ns
    let i = 0
    while (i < units.length - 1 && result >= 1000.0) {
        i += 1
        result /= 1000
    }

    // Display the string
    const unit = units[i]
    return t("t_time_format_unit_override") === "latin"
        ? // Force latin unit (ms, ns)
          new Intl.NumberFormat(getCurrentLanguage(), {
              maximumFractionDigits: unit === "nanosecond" ? 0 : result < 100 ? 1 : 0,
          }).format(result) +
              "\xa0" +
              units_latin[i]
        : // Use localized unit
          new Intl.NumberFormat(getCurrentLanguage(), {
              style: "unit",
              unit,
              maximumFractionDigits: unit === "nanosecond" ? 0 : result < 100 ? 1 : 0,
          })
              .format(result)
              .replaceAll(" ", "\xa0")
}
