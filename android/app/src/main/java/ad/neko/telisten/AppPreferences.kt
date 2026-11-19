package ad.neko.telisten

import android.content.Context
import android.content.res.Configuration
import android.os.LocaleList
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import java.util.Locale

internal enum class AppAppearance(val label: String) {
    SYSTEM("Follow system"), LIGHT("Day mode"), DARK("Night mode");
}

internal enum class AppLanguage(val tag: String, val nativeName: String) {
    SYSTEM("", ""),
    ENGLISH("en", "English"),
    SIMPLIFIED_CHINESE("zh-Hans", "简体中文"),
    TRADITIONAL_CHINESE("zh-Hant", "繁體中文"),
    JAPANESE("ja", "日本語"),
    VIETNAMESE("vi", "Tiếng Việt"),
    FRENCH("fr", "Français"),
    SPANISH("es", "Español"),
    KOREAN("ko", "한국어");

    fun localizedContext(context: Context): Context {
        if (this == SYSTEM) return context
        // Use a local resource configuration without changing the device's locale.
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocales(LocaleList(Locale.forLanguageTag(tag)))
        return context.createConfigurationContext(configuration)
    }
}

internal class AppPreferences(context: Context) {
    private val preferences = context.appPreferences()
    var appearance by mutableStateOf(
        AppAppearance.entries.firstOrNull { it.name == preferences.getString("appearance", null) }
            ?: AppAppearance.SYSTEM
    )
        private set
    var language by mutableStateOf(context.savedAppLanguage())
        private set

    fun selectAppearance(value: AppAppearance) {
        preferences.edit().putString("appearance", value.name).apply()
        appearance = value
    }

    fun selectLanguage(value: AppLanguage) {
        preferences.edit().putString("language", value.tag).apply()
        language = value
    }
}

private fun Context.appPreferences() = getSharedPreferences("app-preferences", Context.MODE_PRIVATE)

internal fun Context.savedAppLanguage(): AppLanguage {
    val tag = appPreferences().getString("language", null)
    return AppLanguage.entries.firstOrNull { it.tag == tag } ?: AppLanguage.SYSTEM
}

internal val LocalAppPreferences = staticCompositionLocalOf<AppPreferences> {
    error("App preferences are unavailable")
}
