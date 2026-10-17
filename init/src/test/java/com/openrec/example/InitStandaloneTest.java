package com.openrec.example;

import org.junit.Test;
import static org.junit.Assert.assertEquals;

public class InitStandaloneTest {
    @Test
    public void reservesBootstrapRevisionForRecallAndSearch() {
        assertEquals("openrec-recall-hot-20260928-r000",
            InitStandalone.bootstrapRecallIndexName("hot", "20260928"));
        assertEquals("openrec-recall-item-search-20260928-r000",
            InitStandalone.bootstrapRecallIndexName("item-search", "20260928"));
    }

    @Test
    public void loadsSearchDocumentsFromModelSchema() throws Exception {
        for (String entity : new String[] {"item", "user"}) {
            String csv = "scene," + entity + ",text\ns," + entity + "_1,hello\n";
            org.apache.commons.csv.CSVRecord row = org.apache.commons.csv.CSVFormat.DEFAULT
                .withFirstRecordAsHeader().parse(new java.io.StringReader(csv)).iterator().next();
            java.util.Map<String, Object> document = InitStandalone.searchDocument(row, entity);
            assertEquals(entity + "_1", document.get(entity));
            assertEquals("hello", document.get("text"));
            assertEquals(3, document.size());
        }
    }

    @Test
    public void acceptsNormalizedLanguageVector() {
        assertEquals(java.util.Arrays.asList(0.6, 0.8), InitStandalone.languageVector("[0.6,0.8]", 2));
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsWrongLanguageVectorDimensions() {
        InitStandalone.languageVector("[1,0]", 1024);
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsUnnormalizedLanguageVector() {
        InitStandalone.languageVector("[3,4]", 2);
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
