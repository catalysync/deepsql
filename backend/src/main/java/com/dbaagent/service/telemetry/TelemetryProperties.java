package com.dbaagent.service.telemetry;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * Binds the telemetry opt-out gates. Most-restrictive wins:
 *   1. DO_NOT_TRACK env var (host-level, industry standard)
 *   2. DEEPSQL_TELEMETRY_DISABLED env var (DeepSQL-specific)
 *   3. Admin UI toggle (this.enabled = false)
 */
@Component
@ConfigurationProperties(prefix = "deepsql.telemetry")
@Data
public class TelemetryProperties {

    // Crate fork: off by default, and the sink is always NoOp (TelemetryConfig).
    private boolean enabled = false;
    private String posthogProjectKey = "";
    private String posthogHost = "";

    public boolean isEffectivelyEnabled(String doNotTrack, String deepsqlOptOut) {
        if (isTruthy(doNotTrack)) return false;
        if (isTruthy(deepsqlOptOut)) return false;
        return enabled;
    }

    private static boolean isTruthy(String s) {
        if (s == null) return false;
        String lower = s.trim().toLowerCase();
        return lower.equals("1") || lower.equals("true") || lower.equals("yes");
    }
}
