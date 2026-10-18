package com.openrec.example.task;

import co.elastic.clients.elasticsearch.ElasticsearchClient;
import co.elastic.clients.elasticsearch.core.BulkRequest;
import co.elastic.clients.elasticsearch.indices.CreateIndexRequest;
import co.elastic.clients.elasticsearch.indices.DeleteIndexRequest;
import co.elastic.clients.elasticsearch.indices.ExistsRequest;
import co.elastic.clients.transport.endpoints.BooleanResponse;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVRecord;
import java.io.IOException;
import java.io.Reader;
import java.io.StringReader;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
import com.openrec.example.InitContext;
import java.nio.file.Path;

@Slf4j
public final class RecallTableTask implements InitTask {
    private final String kind;
    private final String relativePath;

    public RecallTableTask(String kind, String relativePath) {
        this.kind = kind;
        this.relativePath = relativePath;
    }
    private static final String RECALL_INDEX = "{\n" +
            "  \"mappings\": {\"properties\": {\n" +
            "    \"scene\": {\"type\": \"keyword\"},\n" +
            "    \"item\": {\"type\": \"keyword\"},\n" +
            "    \"left_item\": {\"type\": \"keyword\"},\n" +
    "    \"right_item\": {\"type\": \"keyword\"},\n" +
            "    \"user\": {\"type\": \"keyword\"},\n" +
            "    \"left_user\": {\"type\": \"keyword\"},\n" +
            "    \"right_user\": {\"type\": \"keyword\"},\n" +
            "    \"score\": {\"type\": \"double\"},\n" +
            "    \"publish_time\": {\"type\": \"long\"}\n" +
            "  }},\n" +
            "  \"aliases\": {\"%s\": {}}\n" +
            "}";


    @Override
    public String name() {
        return "es-recall-" + kind;
    }

    @Override
    public List<Path> inputs(InitContext context) {
        return List.of(context.model(relativePath));
    }

    @Override
    public void execute(InitContext context) {
        ElasticsearchClient esClient = context.elasticsearch();
        String csvPath = context.model(relativePath).toString();
        String version = LocalDate.now(ZoneOffset.UTC).format(DateTimeFormatter.BASIC_ISO_DATE);
        String indexName = bootstrapRecallIndexName(kind, version);
        String aliasName = String.format("openrec-recall-%s-active", kind);
        try (Reader reader = Files.newBufferedReader(Paths.get(csvPath))) {
            BooleanResponse aliasExists = esClient.indices().existsAlias(a -> a.name(aliasName));
            if (aliasExists.value()) {
                Set<String> aliasedIndexes = esClient.indices().getAlias(a -> a.name(aliasName))
                        .result().keySet();
                for (String aliasedIndex : aliasedIndexes) {
                    esClient.indices().delete(DeleteIndexRequest.of(i -> i.index(aliasedIndex)));
                }
            }
            BooleanResponse currentIndexExists = esClient.indices()
                    .exists(ExistsRequest.of(i -> i.index(indexName)));
            if (currentIndexExists.value()) {
                esClient.indices().delete(DeleteIndexRequest.of(i -> i.index(indexName)));
            }
            boolean created = esClient.indices().create(CreateIndexRequest.of(i -> i.index(indexName)
                    .withJson(new StringReader(String.format(RECALL_INDEX, aliasName))))).acknowledged();
            if (!created) {
                throw new IllegalStateException(indexName + " create failed");
            }

            long now = System.currentTimeMillis() / 1000;
            Iterable<CSVRecord> records = CSVFormat.DEFAULT.withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true).withTrim().parse(reader);
            BulkRequest.Builder bulk = new BulkRequest.Builder();
            int batchCount = 0;
            for (CSVRecord record : records) {
                Map<String, Object> document = new HashMap<>();
                document.put("scene", record.get("scene"));
                document.put("score", Double.valueOf(record.get("score")));
                if (kind.endsWith("i2i")) {
                    document.put("left_item", record.get("left_item"));
                    document.put("right_item", record.get("right_item"));
                } else if (kind.endsWith("u2u")) {
                    document.put("left_user", record.get("left_user"));
                    document.put("right_user", record.get("right_user"));
                } else if ("user-cf-u2i".equals(kind)) {
                    document.put("user", record.get("user"));
                    document.put("item", record.get("item"));
                } else {
                    document.put("item", record.get("item"));
                    if ("new".equals(kind)) {
                        document.put("publish_time",
                                (long)(Double.valueOf(record.get("score")) * now));
                    }
                }
                String id = kind.endsWith("i2i")
                        ? record.get("scene") + ":" + record.get("left_item") + ":" + record.get("right_item")
                        : kind.endsWith("u2u")
                        ? record.get("scene") + ":" + record.get("left_user") + ":" + record.get("right_user")
                        : "user-cf-u2i".equals(kind)
                        ? record.get("scene") + ":" + record.get("user") + ":" + record.get("item")
                        : record.get("scene") + ":" + record.get("item");
                bulk.operations(op -> op.index(idx -> idx.index(indexName).id(id).document(document)));
                batchCount++;
                if (batchCount == 1000) {
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
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        log.info("init {} recall data finished: {} -> {}", kind, indexName, aliasName);
    }
    public static String bootstrapRecallIndexName(String kind, String version) {
        // Reserve r000 for fixture imports; the scheduled publisher starts at r001.
        return String.format("openrec-recall-%s-%s-r000", kind, version);
    }
}
