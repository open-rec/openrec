package com.openrec.example.web.service;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

import com.openrec.client.RecClient;
import com.openrec.example.web.support.Ids;
import com.openrec.proto.JsonRes;
import com.openrec.proto.ProtoCode;
import com.openrec.proto.biz.push.EventReq;
import com.openrec.proto.biz.push.PushCmd;
import com.openrec.proto.model.Event;

import lombok.extern.slf4j.Slf4j;

/**
 * Reports user behaviour back to rec-server through the sdk, and exposes the resulting event
 * counters so the page can show why the recommendations moved.
 * <p>
 * Only two of the five behaviours actually feed the DAG: {@code UserTriggerNode} hardcodes
 * {@code click} when picking triggers and {@code FilterNode} hardcodes {@code expose} when
 * excluding items. {@code buy}, {@code collect} and {@code stay} are stored correctly but no node
 * consumes them today — the page labels that difference rather than implying everything matters.
 */
@Slf4j
@Service
public class FeedbackService {

    private static final String EVENT_KEY = "event:{%s}:%s:%s";
    private static final String TRACE_ID = "openrec-web-";

    /** the behaviours the page can report; the first two are the ones that change recommendations */
    public static final String[] TYPES = {"click", "expose", "buy", "collect", "stay"};

    @Autowired
    private RecClient recClient;

    @Autowired
    private StringRedisTemplate redis;

    /**
     * Sends one event through {@code POST /api/push/event}.
     *
     * @param value type-dependent payload — the dwell time in seconds for {@code stay}, otherwise "1"
     * @return true when rec-server acknowledged it
     */
    public boolean report(String userId, String itemId, String scene, String type, String value) {
        Event event = new Event();
        event.setUserId(userId);
        event.setItemId(itemId);
        event.setScene(scene);
        event.setType(type);
        event.setValue(value == null || value.isEmpty() ? "1" : value);
        event.setTime(String.valueOf(System.currentTimeMillis() / 1000));
        event.setTraceId(TRACE_ID + UUID.randomUUID().toString());
        event.setDeviceId("openrec-web");
        event.setLogin(true);

        EventReq req = new EventReq();
        req.setCmd(PushCmd.INSERT);
        req.setData(Collections.singletonList(event));

        JsonRes<String> res;
        try {
            res = recClient.pushEvents(req);
        } catch (RuntimeException e) {
            log.warn("push {} failed: {}", type, e.getMessage());
            return false;
        }
        if (res == null || res.getCode() != ProtoCode.SUCCESS) {
            log.warn("push {} rejected: {}", type, res == null ? "no response" : res.getCode());
            return false;
        }
        log.info("pushed {} user={} item={} scene={}", type, userId, itemId, scene);
        return true;
    }

    /**
     * Reports one behaviour for many items in a single push.
     * <p>
     * Used to mark a whole page of cards as exposed. The DAG's collector node does this by itself for
     * the tabs it serves; the tables read straight from Redis have no such step, so the web layer
     * does it for them.
     *
     * @return true when rec-server acknowledged the batch
     */
    public boolean reportBatch(String userId, String scene, List<String> itemIds, String type) {
        if (itemIds == null || itemIds.isEmpty()) {
            return true;
        }

        String now = String.valueOf(System.currentTimeMillis() / 1000);
        List<Event> events = new ArrayList<>(itemIds.size());
        for (String itemId : itemIds) {
            Event event = new Event();
            event.setUserId(userId);
            event.setItemId(itemId);
            event.setScene(scene);
            event.setType(type);
            event.setValue("1");
            event.setTime(now);
            event.setTraceId(TRACE_ID + UUID.randomUUID().toString());
            event.setDeviceId("openrec-web");
            event.setLogin(true);
            events.add(event);
        }

        EventReq req = new EventReq();
        req.setCmd(PushCmd.INSERT);
        req.setData(events);

        JsonRes<String> res;
        try {
            res = recClient.pushEvents(req);
        } catch (RuntimeException e) {
            log.warn("batch push {} failed: {}", type, e.getMessage());
            return false;
        }
        if (res == null || res.getCode() != ProtoCode.SUCCESS) {
            log.warn("batch push {} rejected: {}", type, res == null ? "no response" : res.getCode());
            return false;
        }
        log.info("pushed {} x{} user={} scene={}", type, events.size(), userId, scene);
        return true;
    }

    /** Item ids this user has already been shown in this scene. */
    public Set<String> exposedItems(String userId, String scene) {
        Set<String> members = redis.opsForZSet().range(String.format(EVENT_KEY, userId, scene, "expose"), 0, -1);
        if (members == null || members.isEmpty()) {
            return Collections.emptySet();
        }
        // ids written by InitStandalone carry JSON quotes; those pushed through the API do not
        Set<String> exposed = new HashSet<>(members.size());
        for (String member : members) {
            exposed.add(Ids.unquote(member));
        }
        return exposed;
    }

    /** Per-type event counts, so the page can show the history driving the next recommendation. */
    public Map<String, Long> counters(String userId, String scene) {
        Map<String, Long> counts = new LinkedHashMap<>();
        for (String type : TYPES) {
            Long size = redis.opsForZSet().zCard(String.format(EVENT_KEY, userId, scene, type));
            counts.put(type, size == null ? 0L : size);
        }
        return counts;
    }

    /**
     * Clears the exposure history, and optionally the clicks, so the demo can be run repeatedly.
     * <p>
     * Every recommendation makes {@code CollectorNode} write a synthetic {@code expose} record, and
     * {@code FilterNode} then excludes anything exposed within its window (24h by default). After a
     * few refreshes the candidate pool drains and the tab looks broken. This resets it.
     * <p>
     * Done against Redis directly because {@code PushRedisService.pushEvent} only handles
     * INSERT/UPDATE — there is no DELETE path, so the sdk cannot remove events.
     */
    public Map<String, Object> reset(String userId, String scene, boolean clearClicks) {
        Map<String, Object> deleted = new LinkedHashMap<>();

        String exposeKey = String.format(EVENT_KEY, userId, scene, "expose");
        deleted.put("expose", Boolean.TRUE.equals(redis.delete(exposeKey)));

        if (clearClicks) {
            String clickKey = String.format(EVENT_KEY, userId, scene, "click");
            deleted.put("click", Boolean.TRUE.equals(redis.delete(clickKey)));
        }
        log.info("reset user={} scene={} clearClicks={} -> {}", userId, scene, clearClicks, deleted);
        return deleted;
    }
}
