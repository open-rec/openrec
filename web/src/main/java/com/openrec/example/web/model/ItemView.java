package com.openrec.example.web.model;

import lombok.Data;

/** One card on the page: the item as stored in Redis, plus its channel score. */
@Data
public class ItemView {

    private String id;
    private String title;
    private String category;
    private String tags;
    private String scene;
    private String pubTime;
    private double score;

    /**
     * false when {@code item:{id}} was missing or unparsable. The card then shows the raw id rather
     * than rendering blank, which makes a stale recall table obvious instead of silent.
     */
    private boolean resolved;
}
