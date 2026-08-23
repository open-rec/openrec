package com.openrec.example.web.service;

import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import com.openrec.client.RecClient;
import com.openrec.example.web.model.ScoredId;
import com.openrec.example.web.support.Ids;
import com.openrec.proto.JsonRes;
import com.openrec.proto.ProtoCode;
import com.openrec.proto.biz.recommend.RecommendReq;
import com.openrec.proto.biz.recommend.RecommendRes;
import com.openrec.proto.model.Item;
import com.openrec.proto.model.ScoreResult;

import lombok.extern.slf4j.Slf4j;

/**
 * The personalized tabs, served by rec-server through the sdk.
 * <p>
 * "Guess you like" sends no triggers, so {@code userTrigger} derives them from the user's recent
 * clicks in Redis — which is exactly why feedback reported from the page changes this tab on the
 * next request. "Related" additionally passes the item being viewed as an explicit trigger.
 */
@Slf4j
@Service
public class RecommendService {

    @Autowired
    private RecClient recClient;

    /** Personalized: triggers come from the user's own click history. */
    public List<ScoredId> guessYouLike(String scene, String userId, int size, String experiment) {
        return recommend(buildReq(scene, userId, size, null, experiment), "guess");
    }

    /** Related: the given item is passed as an explicit trigger on top of the click history. */
    public List<ScoredId> related(String scene, String userId, String itemId, int size, String experiment) {
        return recommend(buildReq(scene, userId, size, itemId, experiment), "related");
    }

    private RecommendReq buildReq(String scene, String userId, int size, String triggerItemId,
        String experiment) {
        RecommendReq req = new RecommendReq();
        req.setScene(scene);
        req.setUserId(userId);
        req.setSize(size);
        // an unlogged visitor would only have this; sent for completeness
        req.setDeviceId("openrec-web");
        req.setType("click");
        if (triggerItemId != null && !triggerItemId.isEmpty()) {
            req.setItemIds(Collections.singletonList(triggerItemId));
        }
        Map<String, Object> params = new HashMap<>();
        params.put("ab", experiment == null || experiment.isEmpty() ? "default" : experiment);
        req.setParams(params);
        return req;
    }

    private List<ScoredId> recommend(RecommendReq req, String label) {
        JsonRes<RecommendRes<Item>> res;
        try {
            res = recClient.recommend(req);
        } catch (RuntimeException e) {
            // the sdk rethrows transport failures; a dead rec-server should not take the page down
            log.warn("{} recommend failed: {}", label, e.getMessage());
            return Collections.emptyList();
        }

        // the sdk returns null for any non-2xx response rather than throwing
        if (res == null) {
            log.warn("{} recommend got no response, is rec-server up?", label);
            return Collections.emptyList();
        }
        if (res.getCode() != ProtoCode.SUCCESS || res.getData() == null) {
            log.warn("{} recommend returned code={} msg={}", label, res.getCode(), res.getMsg());
            return Collections.emptyList();
        }

        List<ScoreResult> results = res.getData().getResults();
        if (results == null || results.isEmpty()) {
            log.info("{} recommend returned no items for scene={} user={}", label, req.getScene(), req.getUserId());
            return Collections.emptyList();
        }

        return results.stream().map(result -> {
            // rec-server hands back quoted ids on the i2i path; normalize before anything downstream
            // tries to look them up
            result.setId(Ids.unquote(result.getId()));
            return ScoredId.from(result, null);
        }).collect(Collectors.toList());
    }
}
