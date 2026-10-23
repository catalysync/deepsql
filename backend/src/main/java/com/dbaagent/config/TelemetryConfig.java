package com.dbaagent.config;

import com.dbaagent.service.telemetry.NoOpTelemetrySink;
import com.dbaagent.service.telemetry.TelemetrySink;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Crate fork: telemetry is removed. The only TelemetrySink is the no-op sink,
 * whatever the properties or env say. The upstream PostHogDirectSink (the one
 * class that POSTed to us.i.posthog.com) has been deleted, so there is no code
 * path that sends install or usage data anywhere. See docs/crate/TELEMETRY-REMOVED.md.
 */
@Configuration
@Slf4j
public class TelemetryConfig {

    @Bean
    public TelemetrySink telemetrySink() {
        log.info("Telemetry removed in this build; using NoOpTelemetrySink");
        return new NoOpTelemetrySink();
    }
}
