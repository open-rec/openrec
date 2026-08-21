package com.openrec.example.web.controller;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.openrec.example.web.service.FeedbackService;

import lombok.Data;

/** Behaviour reporting, the event counters behind it, and the reset that makes the demo repeatable. */
@RestController
@RequestMapping("/api")
public class FeedbackController {

    @Autowired
    private FeedbackService feedbackService;

    @Value("${demo.user-id}")
    private String defaultUserId;

    @Value("${demo.scene}")
    private String defaultScene;

    @Data
    public static class FeedbackReq {
        private String userId;
        private String itemId;
        private String scene;
        private String type;
        /** dwell seconds for stay, ignored otherwise */
        private String value;
    }

    @Data
    public static class BatchFeedbackReq {
        private String userId;
        private List<String> itemIds;
        private String scene;
        private String type;
    }

    @PostMapping("/feedback")
    public Map<String, Object> feedback(@RequestBody FeedbackReq req) {
        Map<String, Object> body = new LinkedHashMap<>();

        if (isBlank(req.getItemId()) || isBlank(req.getType())) {
            body.put("ok", false);
            body.put("error", "itemId and type are required");
            return body;
        }

        String userId = orDefault(req.getUserId(), defaultUserId);
        String scene = orDefault(req.getScene(), defaultScene);

        boolean ok = feedbackService.report(userId, req.getItemId(), scene, req.getType(), req.getValue());
        body.put("ok", ok);
        body.put("type", req.getType());
        body.put("itemId", req.getItemId());
        // returned so the page can refresh its counters without a second round trip
        body.put("counters", feedbackService.counters(userId, scene));
        if (!ok) {
            body.put("error", "rec-server did not accept the event, check its log");
        }
        return body;
    }

    @PostMapping("/feedback/batch")
    public Map<String, Object> feedbackBatch(@RequestBody BatchFeedbackReq req) {
        Map<String, Object> body = new LinkedHashMap<>();
        if (req.getItemIds() == null || req.getItemIds().isEmpty() || isBlank(req.getType())) {
            body.put("ok", false);
            body.put("error", "itemIds and type are required");
            return body;
        }
        String userId = orDefault(req.getUserId(), defaultUserId);
        String scene = orDefault(req.getScene(), defaultScene);
        boolean ok = feedbackService.reportBatch(userId, scene, req.getItemIds(), req.getType());
        body.put("ok", ok);
        body.put("type", req.getType());
        body.put("count", req.getItemIds().size());
        body.put("counters", feedbackService.counters(userId, scene));
        if (!ok) body.put("error", "rec-server did not accept the event batch, check its log");
        return body;
    }

    /** Event counts per type: the history that shapes the next recommendation. */
    @GetMapping("/state")
    public Map<String, Object> state(@RequestParam(required = false) String userId,
        @RequestParam(required = false) String scene) {
        String u = orDefault(userId, defaultUserId);
        String s = orDefault(scene, defaultScene);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("userId", u);
        body.put("scene", s);
        body.put("counters", feedbackService.counters(u, s));
        return body;
    }

    @Data
    public static class ResetReq {
        private String userId;
        private String scene;
        /** also drop the click history, returning this user to a cold start */
        private boolean clearClicks;
    }

    @PostMapping("/reset")
    public Map<String, Object> reset(@RequestBody(required = false) ResetReq req) {
        ResetReq r = req == null ? new ResetReq() : req;
        String u = orDefault(r.getUserId(), defaultUserId);
        String s = orDefault(r.getScene(), defaultScene);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("ok", true);
        body.put("deleted", feedbackService.reset(u, s, r.isClearClicks()));
        body.put("counters", feedbackService.counters(u, s));
        return body;
    }

    @PostMapping("/reset/dislike")
    public Map<String, Object> resetDislike(@RequestBody(required = false) ResetReq req) {
        ResetReq r = req == null ? new ResetReq() : req;
        String u = orDefault(r.getUserId(), defaultUserId);
        String s = orDefault(r.getScene(), defaultScene);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("ok", true);
        body.put("deleted", feedbackService.resetDislikes(u, s));
        body.put("counters", feedbackService.counters(u, s));
        return body;
    }

    private boolean isBlank(String value) {
        return value == null || value.isEmpty();
    }

    private String orDefault(String value, String fallback) {
        return isBlank(value) ? fallback : value;
    }
}
