package app.xyz.everydayapp.syncing_keys

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

/**
 * Verifies the plugin's MethodChannel router responds to the
 * `getPlatformVersion` debug call with the expected payload.
 *
 * Run via `./gradlew testDebugUnitTest` inside the example project's
 * `android/` folder.
 */
internal class SyncingKeysPluginTest {
    @Test
    fun onMethodCall_getPlatformVersion_returnsExpectedValue() {
        val plugin = SyncingKeysPlugin()

        val call = MethodCall("getPlatformVersion", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success("Android " + android.os.Build.VERSION.RELEASE)
    }
}
