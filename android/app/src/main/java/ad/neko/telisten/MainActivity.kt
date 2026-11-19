package ad.neko.telisten

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.core.view.WindowCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import ad.neko.telisten.ui.TelistenTheme
import ad.neko.telisten.ui.TelistenApp
import ad.neko.telisten.ui.AppModel
import ad.neko.telisten.ui.appUsesDarkTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val preferences = AppPreferences(this)
        setContent {
            CompositionLocalProvider(LocalAppPreferences provides preferences) {
                val darkTheme = appUsesDarkTheme()
                SideEffect {
                    WindowCompat.getInsetsController(window, window.decorView).apply {
                        isAppearanceLightStatusBars = !darkTheme
                        isAppearanceLightNavigationBars = !darkTheme
                    }
                }
                TelistenTheme {
                    val model: AppModel = viewModel()
                    androidx.compose.runtime.LaunchedEffect(Unit) { if (BuildConfig.DEBUG && intent.getBooleanExtra("demo", false)) { model.enableDemo(); intent.removeExtra("demo") } }
                    ProvideAppLocalization { TelistenApp(model) }
                }
            }
        }
    }
}
