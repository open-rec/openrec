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
 * Neither tab can go through {@code /api/recommend}: the DAG in {@code graph.json} always runs
 * every channel and merges them, and nothing in the request selects one — {@code RecommendReq.type}
 * exists but no node reads it. Worse, the {@code new} channel yields nothing at all on the sample
 * dataset: {@code InitStandalone} writes a 0..1 normalized score into {@code new:{scene}} while
 * {@code NewNode} filters by a {@code [now - duration, now]} timestamp range, which never matches.
 * Reading the tables directly is what actually shows the data these tabs are named after.
 */
@Slf4j
@Service
public class RecallTableService {

    private static final String HOT_KEY = "hot:{%s}";
    private static final String NEW_KEY = "new:{%s}";

    @Autowired
    private StringRedisTemplate redis;

    public List<ScoredId> hot(String scene, int size) {
        return topN(String.format(HOT_KEY, scene), size);
    }

    /** {@code new} is a java keyword, hence the name. */
    public List<ScoredId> fresh(String scene, int size) {
        return topN(String.format(NEW_KEY, scene), size);
    }

    private List<ScoredId> topN(String key, int size) {
        Set<ZSetOperations.TypedTuple<String>> tuples =
            redis.opsForZSet().reverseRangeWithScores(key, 0, Math.max(size - 1, 0));
        if (tuples == null || tuples.isEmpty()) {
            log.info("recall table {} is empty", key);
            return Collections.emptyList();
        }

        List<ScoredId> result = new ArrayList<>(tuples.size());
        for (ZSetOperations.TypedTuple<String> tuple : tuples) {
            if (tuple.getValue() == null) {
                continue;
            }
            double score = tuple.getScore() == null ? 0d : tuple.getScore();
            result.add(new ScoredId(Ids.unquote(tuple.getValue()), score));
        }
        return result;
    }
}
