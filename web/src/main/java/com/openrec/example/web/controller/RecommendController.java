package com.openrec.example.web.controller;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.openrec.example.web.model.ItemView;
import com.openrec.example.web.model.ScoredId;
import com.openrec.example.web.service.FeedbackService;
import com.openrec.example.web.service.ItemService;
import com.openrec.example.web.service.RecallTableService;
import com.openrec.example.web.service.RecommendService;

/**
 * One endpoint for all four tabs. Each response says where its data came from, so the page can be
 * explicit about which tabs go through rec-server and which read the recall tables directly.
 */
@RestController
@RequestMapping("/api")
public class RecommendController {

    private static final String VIA_SDK = "rec-server /api/recommend (via rec-client)";

    /** Tabs that read Redis directly and therefore have to do their own exposure bookkeeping. */
    private static final Set<String> DIRECT_TABLE_TABS = new HashSet<>(Arrays.asList("hot", "new"));

    @Autowired
    private RecommendService recommendService;

    @Autowired
    private RecallTableService recallTableService;

    @Autowired
    private ItemService itemService;

    @Autowired
    private FeedbackService feedbackService;

    @Value("${demo.user-id}")
    private String defaultUserId;

    @Value("${demo.scene}")
    private String defaultScene;

    @Value("${demo.page-size}")
    private int defaultSize;

    @Value("${demo.exposure-mode:server}")
    private String exposureMode;

    /**
     * @param name   guess | related | hot | new
     * @param itemId trigger item, used by the related tab only
     */
    @GetMapping("/tab/{name}")
    public Map<String, Object> tab(@PathVariable String name,
        @RequestParam(required = false) String scene,
        @RequestParam(required = false) String userId,
        @RequestParam(required = false) Integer size,
        @RequestParam(required = false) String itemId) {

        String s = isBlank(scene) ? defaultScene : scene;
        String u = isBlank(userId) ? defaultUserId : userId;
        int n = (size == null || size <= 0) ? defaultSize : size;

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("tab", name);
        body.put("scene", s);
        body.put("userId", u);
        body.put("personalized", false);

        List<ScoredId> ids;
        switch (name) {
            case "guess":
                ids = recommendService.guessYouLike(s, u, n);
                body.put("source", VIA_SDK);
                body.put("note", "triggers come from this user's click history — feedback shows up here");
                body.put("personalized", true);
                break;
            case "related":
                if (isBlank(itemId)) {
                    body.put("source", VIA_SDK);
                    body.put("note", "pick an item first: related recall needs a trigger item");
                    body.put("count", 0);
                    body.put("items", Collections.emptyList());
                    return body;
                }
                ids = recommendService.related(s, u, itemId, n);
                body.put("triggerItemId", itemId);
                body.put("source", VIA_SDK);
                body.put("note", "the selected item is sent as an explicit trigger");
                body.put("personalized", true);
                break;
            case "hot":
                ids = recallTableService.hot(s, n, feedbackService.exposedItems(u, s));
                body.put("source", "redis hot:{" + s + "}");
                body.put("note", "read from the recall table, already-exposed items excluded here "
                    + "because this path skips the DAG's filter node");
                break;
            case "new":
                ids = recallTableService.fresh(s, n, feedbackService.exposedItems(u, s));
                body.put("source", "redis new:{" + s + "}");
                body.put("note", "read from the recall table; already-exposed items are excluded "
                    + "here because this path skips the DAG's filter node");
                break;
            default:
                body.put("error", "unknown tab '" + name + "', expected guess|related|hot|new");
                body.put("count", 0);
                body.put("items", Collections.emptyList());
                return body;
        }

        List<ItemView> items = itemService.resolve(ids);

        // In standalone, rendering a card counts as exposing it. DAG-backed tabs get this from
        // Collector and direct-table tabs need the same fallback here. Cluster uses browser-visible
        // exposure instead, so neither server-side path reports it in viewport mode.
        if ("server".equalsIgnoreCase(exposureMode)
            && DIRECT_TABLE_TABS.contains(name) && !items.isEmpty()) {
            List<String> shown = items.stream().map(ItemView::getId).collect(Collectors.toList());
            body.put("exposeReported", feedbackService.reportBatch(u, s, shown, "expose"));
        }

        body.put("count", items.size());
        body.put("items", items);
        return body;
    }

    private boolean isBlank(String value) {
        return value == null || value.isEmpty();
    }
}
