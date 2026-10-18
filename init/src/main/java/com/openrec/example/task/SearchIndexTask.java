package com.openrec.example.task;

import co.elastic.clients.elasticsearch.ElasticsearchClient;
import co.elastic.clients.elasticsearch.core.BulkRequest;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVRecord;
import java.io.IOException;
import java.io.Reader;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
import com.openrec.example.InitContext;
import java.nio.file.Path;

@Slf4j
public final class SearchIndexTask implements InitTask {
    private final String entity;

    public SearchIndexTask(String entity) {
        if (!List.of("item", "user").contains(entity)) {
            throw new IllegalArgumentException("search entity must be item or user");
        }
        this.entity = entity;
    }

    @Override
    public String name() {
        return "es-" + entity + "-search";
    }

    @Override
    public List<Path> inputs(InitContext context) {
        return List.of(context.model("recall/" + entity + "/text_search.csv"));
    }

    @Override
    public void execute(InitContext context) {
        ElasticsearchClient esClient = context.elasticsearch();
        String csvPath = context.model("recall/" + entity + "/text_search.csv").toString();
        String kind = entity + "-search";
        String version = LocalDate.now(ZoneOffset.UTC).format(DateTimeFormatter.BASIC_ISO_DATE);
        String indexName = RecallTableTask.bootstrapRecallIndexName(kind, version) + System.currentTimeMillis();
        String aliasName = "openrec-recall-" + kind + "-active";
        try (Reader reader = Files.newBufferedReader(Paths.get(csvPath))) {
            Iterable<CSVRecord> records = CSVFormat.DEFAULT.withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true).withTrim().parse(reader);
            esClient.indices().create(i -> i.index(indexName).mappings(m -> m
                    .properties("scene", v -> v.keyword(k -> k))
                    .properties(entity, v -> v.keyword(k -> k))
                    .properties("text", v -> v.text(t -> t.similarity("BM25")))));
            BulkRequest.Builder bulk = new BulkRequest.Builder();
            int batchCount = 0;
            long count = 0;
            for (CSVRecord record : records) {
                Map<String, Object> document = searchDocument(record, entity);
                String id = document.get("scene") + ":" + document.get(entity);
                bulk.operations(op -> op.index(idx -> idx.index(indexName).id(id).document(document)));
                count++;
                if (++batchCount == 1000) {
                    if (esClient.bulk(bulk.build()).errors()) {
                        throw new IllegalStateException(indexName + " bulk load failed");
                    }
                    bulk = new BulkRequest.Builder();
                    batchCount = 0;
                }
            }
            if (batchCount > 0 && esClient.bulk(bulk.build()).errors()) {
                throw new IllegalStateException(indexName + " bulk load failed");
            }
            esClient.indices().refresh(i -> i.index(indexName));
            if (count == 0 || esClient.count(c -> c.index(indexName)).count() != count) {
                throw new IllegalStateException(indexName + " document count mismatch or empty input");
            }
            List<String> previous = new ArrayList<>();
            if (esClient.indices().existsAlias(a -> a.name(aliasName)).value()) {
                previous.addAll(esClient.indices().getAlias(a -> a.name(aliasName)).result().keySet());
            }
            esClient.indices().updateAliases(a -> {
                for (String old : previous) {
                    a.actions(action -> action.remove(remove -> remove.index(old).alias(aliasName)));
                }
                return a.actions(action -> action.add(add -> add.index(indexName).alias(aliasName)));
            });
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init {} data finished: {} -> {}", kind, indexName, aliasName);
    }
    public static Map<String, Object> searchDocument(CSVRecord record, String entity) {
        if (!entity.equals("item") && !entity.equals("user")) {
            throw new IllegalArgumentException("search entity must be item or user");
        }
        Map<String, Object> document = new HashMap<>();
        for (String field : Arrays.asList("scene", entity, "text")) {
            String value = record.get(field);
            if (value.isBlank()) {
                throw new IllegalArgumentException("empty search field: " + field);
            }
            document.put(field, value);
        }
        return document;
    }
}
