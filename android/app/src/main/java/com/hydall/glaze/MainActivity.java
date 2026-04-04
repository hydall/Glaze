package com.hydall.glaze;

import com.getcapacitor.BridgeActivity;
import android.os.Bundle;
import androidx.activity.EdgeToEdge;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(MessagingStyleNotificationPlugin.class);
        super.onCreate(savedInstanceState);
        // Enable edge-to-edge mode for modern Android versions
        EdgeToEdge.enable(this);
    }

    @Override
    public void onResume() {
        super.onResume();
        
        // Allow Mixed Content (HTTP requests in HTTPS context)
        android.webkit.WebView webView = this.bridge.getWebView();
        android.webkit.WebSettings settings = webView.getSettings();
        settings.setMixedContentMode(android.webkit.WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        
        // Chromium bug polyfill: Manually push Edge-to-Edge insets as CSS variables.
        // This bridges the gap for older WebView versions that don't pipe these to env() natively.
        androidx.core.view.ViewCompat.setOnApplyWindowInsetsListener(webView, (v, insets) -> {
            androidx.core.graphics.Insets safeArea = insets.getInsets(
                    androidx.core.view.WindowInsetsCompat.Type.systemBars() | 
                    androidx.core.view.WindowInsetsCompat.Type.displayCutout());
            
            float density = getResources().getDisplayMetrics().density;
            int topPx = (int)(safeArea.top / density);
            int bottomPx = (int)(safeArea.bottom / density);
            
            String js = String.format(java.util.Locale.US, 
                "document.documentElement.style.setProperty('--safe-area-inset-top', '%dpx');" +
                "document.documentElement.style.setProperty('--safe-area-inset-bottom', '%dpx');", 
                topPx, bottomPx);
                
            webView.evaluateJavascript(js, null);
            
            // Do not consume the event, let it propagate to other listeners or plugins.
            return androidx.core.view.ViewCompat.onApplyWindowInsets(v, insets);
        });
    }
}
