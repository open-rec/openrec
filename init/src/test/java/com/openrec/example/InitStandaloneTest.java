package com.openrec.example;

import org.junit.Test;
import static org.junit.Assert.assertEquals;

public class InitStandaloneTest {
    @Test
    public void reservesBootstrapRevisionForRecallAndSparse() {
        assertEquals("openrec-recall-hot-20260928-r000",
            InitStandalone.bootstrapRecallIndexName("hot", "20260928"));
        assertEquals("openrec-recall-sparse-20260928-r000",
            InitStandalone.bootstrapRecallIndexName("sparse", "20260928"));
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsMissingConnectionArguments() {
        InitStandalone.main(new String[0]);
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsMissingDataDirectory() {
        InitStandalone.main(new String[] {"127.0.0.1", "6380", "127.0.0.1", "9200",
            "elastic", "test-password", "/nonexistent-openrec-test-input"});
    }
}
