package com.openrec.example.web.controller;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestTemplate;

/** Exposes enabled rec-server experiments to the demo without leaking the management token. */
@RestController
@RequestMapping("/api")
public class ExperimentController {

    @Value("${rec.server.endpoint}")
    private String recServerEndpoint;

    @Value("${rec.server.serving-graph-token:openrec-serving-graph-token-change-me}")
    private String servingGraphToken;

    private final RestTemplate restTemplate = new RestTemplate();

    @GetMapping("/experiments")
    @SuppressWarnings("unchecked")
    public Map<String, Object> experiments() {
        try {
            HttpHeaders headers = new HttpHeaders();
            headers.set("X-OpenRec-Token", servingGraphToken);
            ResponseEntity<Map> response = restTemplate.exchange(
                recServerEndpoint + "/internal/serving-graph", HttpMethod.GET,
                new HttpEntity<>(headers), Map.class);
            Map<String, Object> envelope = response.getBody();
            Map<String, Object> data = envelope == null ? null : (Map<String, Object>) envelope.get("data");
            Map<String, Object> all = data == null ? null : (Map<String, Object>) data.get("experiments");
            List<String> enabled = new ArrayList<>();
            if (all != null) {
                all.forEach((name, raw) -> {
                    if (raw instanceof Map && Boolean.TRUE.equals(((Map<?, ?>) raw).get("enabled"))) {
                        enabled.add(name);
                    }
                });
            }
            if (!enabled.contains("default")) enabled.add("default");
            Collections.sort(enabled);
            return Collections.singletonMap("experiments", enabled);
        } catch (RuntimeException error) {
            return Collections.singletonMap("experiments", Collections.singletonList("default"));
        }
    }
}
