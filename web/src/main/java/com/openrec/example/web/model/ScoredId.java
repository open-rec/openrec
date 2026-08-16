package com.openrec.example.web.model;

import lombok.AllArgsConstructor;
import lombok.Data;

/** An item id together with the score of whichever channel produced it. */
@Data
@AllArgsConstructor
public class ScoredId {

    private String id;
    private double score;
}
