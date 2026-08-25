package com.openrec.example.web.service;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;
import org.springframework.util.CollectionUtils;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.openrec.example.web.model.ItemView;
import com.openrec.example.web.model.ScoredId;
import com.openrec.proto.model.Item;

import lombok.extern.slf4j.Slf4j;

/**
 * Turns item ids into displayable cards by reading {@code item:{id}} out of Redis.
 * <p>
 * rec-server has {@code GET /api/query/item/{itemId}}, but only one id per call; a tab needs a
 * dozen, so these are batched with MGET instead.
 */
@Slf4j
@Service
public class ItemService {

    private static final String ITEM_KEY = "item:{%s}";

    private final ObjectMapper mapper =
        new ObjectMapper().configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    @Autowired
    private StringRedisTemplate redis;

    /**
     * Resolves in the order given — every channel already sorted by score, and that order is what
     * the page should render.
     */
    public List<ItemView> resolve(List<ScoredId> scoredIds) {
        if (CollectionUtils.isEmpty(scoredIds)) {
            return Collections.emptyList();
        }

        List<String> keys =
            scoredIds.stream().map(s -> String.format(ITEM_KEY, s.getId())).collect(Collectors.toList());
        List<String> raw = redis.opsForValue().multiGet(keys);

        List<ItemView> views = new ArrayList<>(scoredIds.size());
        for (int i = 0; i < scoredIds.size(); i++) {
            String json = (raw == null || i >= raw.size()) ? null : raw.get(i);
            views.add(toView(scoredIds.get(i), json));
        }
        return views;
    }

    /**
     * Renders the scoring breakdown as
     * {@code recall=item_cf_i2i:0.1700,hot:1.0000; rank=0.7700}.
     * <p>
     * A dash rather than 0 for a stage that did not run: "the rank engine is down" and "the model
     * scored this 0" call for different reactions when tuning by hand.
     */
    private String buildMeta(ScoredId scored) {
        StringBuilder meta = new StringBuilder("recall=");

        Map<String, Double> recalls = scored.getRecallScores();
        if (recalls != null && !recalls.isEmpty()) {
            boolean first = true;
            for (Map.Entry<String, Double> entry : recalls.entrySet()) {
                if (!first) {
                    meta.append(',');
                }
                meta.append(entry.getKey()).append(':').append(format(entry.getValue()));
                first = false;
            }
        } else if (scored.getRecallFrom() != null) {
            meta.append(scored.getRecallFrom()).append(':').append(format(scored.getRecallScore()));
        } else {
            meta.append('-');
        }

        return meta.append("; rank=").append(format(scored.getRankScore())).toString();
    }

    private String format(Double value) {
        return value == null ? "-" : String.format("%.4f", value);
    }

    private ItemView toView(ScoredId scored, String json) {
        ItemView view = new ItemView();
        view.setId(scored.getId());
        view.setScore(scored.getScore());
        view.setRecallFrom(scored.getRecallFrom());
        view.setRecallScore(scored.getRecallScore());
        view.setRankScore(scored.getRankScore());
        view.setRecallScores(scored.getRecallScores());
        view.setMeta(buildMeta(scored));

        if (json == null) {
            view.setResolved(false);
            view.setTitle(scored.getId());
            return view;
        }

        try {
            Item item = mapper.readValue(json, Item.class);
            view.setResolved(true);
            view.setTitle(item.getTitle());
            view.setCategory(item.getCategory());
            view.setTags(item.getTags());
            view.setScene(item.getScene());
            view.setPubTime(item.getPubTime());
            view.setModifyTime(item.getModifyTime());
            view.setExpireTime(item.getExpireTime());
            view.setWeight(item.getWeight());
            view.setStatus(item.getStatus());
            view.setExtFields(item.getExtFields());
        } catch (Exception e) {
            log.warn("cannot parse item {}: {}", scored.getId(), e.getMessage());
            view.setResolved(false);
            view.setTitle(scored.getId());
        }
        return view;
    }
}
