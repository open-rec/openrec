package com.openrec.example.web.controller;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.openrec.example.web.service.FeedbackService;

/** Page defaults, so the front end does not hardcode the demo user, the scene list or which
 *  behaviours actually influence recall. */
@RestController
@RequestMapping("/api")
public class DemoConfigController {

    @Value("${demo.user-id}")
    private String userId;

    @Value("${demo.scene}")
    private String scene;

    @Value("${demo.scenes}")
    private String[] scenes;

    @Value("${demo.page-size}")
    private int pageSize;

    @Value("${rec.server.endpoint}")
    private String recServerEndpoint;

    @GetMapping("/config")
    public Map<String, Object> config() {
        Map<String, Object> cfg = new LinkedHashMap<>();
        cfg.put("userId", userId);
        cfg.put("scene", scene);
        cfg.put("scenes", scenes);
        cfg.put("pageSize", pageSize);
        cfg.put("recServer", recServerEndpoint);
        cfg.put("behaviours", Arrays.asList(FeedbackService.TYPES));
        // the only two the DAG consumes today: userTrigger reads click, filter reads expose
        cfg.put("affectingBehaviours", Arrays.asList("click", "expose"));
        return cfg;
    }
}
