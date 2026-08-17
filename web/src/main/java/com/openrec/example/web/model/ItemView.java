package com.openrec.example.web.model;

import java.util.Map;

import lombok.Data;

/** One card on the page: the item as stored in Redis, plus how it was scored. */
@Data
public class ItemView {

    private String id;
    private String title;
    private String category;
    private String tags;
    private String scene;
    private String pubTime;

    /** final score the list is ordered by */
    private double score;

    /** the channel whose score ranks this item: i2i / embedding / hot / new */
    private String recallFrom;

    /** score before ranking; null when the item did not go through the DAG's rank stage */
    private Double recallScore;

    /** the rank engine's contribution; null when ranking was skipped or failed */
    private Double rankScore;

    /** every channel that recalled it, with each one's score */
    private Map<String, Double> recallScores;

    /**
     * The breakdown as one readable line, e.g. {@code recall=i2i:0.1700,hot:1.0000; rank=0.7700}.
     * Rendered on the card so the channel mix and both stage scores can be read — and copied — while
     * tuning the strategy by hand.
     */
    private String meta;

    /**
     * false when {@code item:{id}} was missing or unparsable. The card then shows the raw id instead
     * of rendering blank, which makes a stale recall table visible rather than silent.
     */
    private boolean resolved;
}
