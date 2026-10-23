package com.dbaagent.config;

import com.dbaagent.service.telemetry.NoOpTelemetrySink;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertInstanceOf;

/** Crate fork: the only sink is the no-op sink; there is no sender to select. */
class TelemetryConfigTest {

    @Test
    void sinkIsAlwaysNoOp() {
        assertInstanceOf(NoOpTelemetrySink.class, new TelemetryConfig().telemetrySink());
    }
}
