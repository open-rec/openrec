package com.openrec.example.web.model;

import java.util.Collections;
import java.util.Map;

import com.openrec.proto.model.ScoreResult;

import lombok.Data;

/**
 * An item id plus whatever the producing stage knows about it. The recall/rank breakdown is only
 * present for the tabs served by rec-server's DAG; the tables read straight from Redis fill in the
 * channel name themselves and leave the rest null.
 */
@Data
public class ScoredId {

    private String id;
    private double score;
    private String recallFrom;
    private Double recallScore;
    private Double rankScore;

    /** every channel that recalled this item, with the score each gave it */
    private Map<String, Double> recallScores;

    public ScoredId(String id, double score) {
        this.id = id;
        this.score = score;
    }

    /** For the tables read straight from Redis: a single channel, which is its own breakdown. */
    public ScoredId(String id, double score, String recallFrom) {
        this(id, score);
        this.recallFrom = recallFrom;
        this.recallScore = score;
        this.recallScores = Collections.singletonMap(recallFrom, score);
    }

    /** Carries the DAG's attribution through: which channels recalled it, and both stage scores. */
    public static ScoredId from(ScoreResult result, String fallbackChannel) {
        ScoredId scored = new ScoredId(result.getId(), result.getScore());
        scored.setRecallFrom(result.getRecallFrom() == null ? fallbackChannel : result.getRecallFrom());
        scored.setRecallScore(result.getRecallScore());
        scored.setRankScore(result.getRankScore());
        scored.setRecallScores(result.getRecallScores());
        return scored;
    }
}
