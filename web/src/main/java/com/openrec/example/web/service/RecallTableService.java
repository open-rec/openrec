package com.openrec.example.web.service;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ZSetOperations;
import org.springframework.stereotype.Service;

import com.openrec.example.web.model.ScoredId;
import com.openrec.example.web.support.Ids;

import lombok.extern.slf4j.Slf4j;

/**
 * Reads the hot and new recall tables straight out of Redis.
 * <p>
 * Neither tab can go through {@code /api/recommend}: the DAG in {@code graph.json} always runs every
 * channel and merges them, and nothing in the request selects one — {@code RecommendReq.type} exists
 * but no node reads it. The {@code new} channel also yields nothing on the sample dataset, because
 * {@code InitStandalone} writes a 0..1 normalized score into {@code new:{scene}} while
 * {@code NewNode} filters by a {@code [now - duration, now]} timestamp range.
 * <p>
 * Because these bypass the DAG they also bypass its {@code filter} node, so exposure filtering is
 * applied here instead — otherwise these two tabs would keep showing what the user has already seen
 * while the DAG-backed tabs correctly stop doing so.
 */
@Slf4j
@Service
public class RecallTableService {

    private static final String HOT_KEY = "hot:{%s}";
    private static final String NEW_KEY = "new:{%s}";

    @Autowired
    private StringRedisTemplate redis;

    public List<ScoredId> hot(String scene, int size, Set<String> exclude) {
        return topN(String.format(HOT_KEY, scene), size, exclude, "hot");
    }

    /** {@code new} is a java keyword, hence the name. */
    public List<ScoredId> fresh(String scene, int size, Set<String> exclude) {
        return topN(String.format(NEW_KEY, scene), size, exclude, "new");
    }

    private List<ScoredId> topN(String key, int size, Set<String> exclude, String channel) {
        // fetch enough rows to still fill a page after the excluded ones are dropped
        int fetch = size + (exclude == null ? 0 : exclude.size());
        Set<ZSetOperations.TypedTuple<String>> tuples =
            redis.opsForZSet().reverseRangeWithScores(key, 0, Math.max(fetch - 1, 0));
        if (tuples == null || tuples.isEmpty()) {
            log.info("recall table {} is empty", key);
            return Collections.emptyList();
        }

        List<ScoredId> result = new ArrayList<>(size);
        for (ZSetOperations.TypedTuple<String> tuple : tuples) {
            if (result.size() >= size) {
                break;
            }
            if (tuple.getValue() == null) {
                continue;
            }
            String id = Ids.unquote(tuple.getValue());
            if (exclude != null && exclude.contains(id)) {
                continue;
            }
            double score = tuple.getScore() == null ? 0d : tuple.getScore();
            result.add(new ScoredId(id, score, channel));
        }
        return result;
    }
}
