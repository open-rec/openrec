package com.openrec.example.task;

import lombok.extern.slf4j.Slf4j;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVRecord;
import org.springframework.data.redis.core.RedisTemplate;
import java.io.IOException;
import java.io.Reader;
import java.nio.file.Files;
import java.util.*;
import com.openrec.example.InitContext;
import java.nio.file.Path;

@Slf4j
public final class RedisFeatureTask implements InitTask {
    private final String entityType;

    public RedisFeatureTask(String entityType) {
        if (!List.of("item", "user").contains(entityType)) {
            throw new IllegalArgumentException("feature entity must be item or user");
        }
        this.entityType = entityType;
    }

    @Override
    public String name() {
        return "redis-" + entityType + "-features";
    }

    @Override
    public List<Path> inputs(InitContext context) {
        return List.of(context.model("rank/item/lr/" + entityType + "_feature.csv"));
    }

    @Override
    public void execute(InitContext context) {
        RedisTemplate redisTemplate = context.redis();
        java.nio.file.Path path = context.model("rank/item/lr/" + entityType + "_feature.csv");
        int count = 0;
        try (Reader reader = Files.newBufferedReader(path)) {
            Iterable<CSVRecord> records = CSVFormat.DEFAULT.withFirstRecordAsHeader()
                    .withIgnoreEmptyLines(true).withTrim().parse(reader);
            for (CSVRecord record : records) {
                String entityId = record.get("id");
                long asOfTime = record.isMapped("as_of_time") && !record.get("as_of_time").isEmpty()
                        ? Double.valueOf(record.get("as_of_time")).longValue() : 0L;
                Map<String, Double> features = new LinkedHashMap<>();
                for (String column : record.toMap().keySet()) {
                    if (column.startsWith("event_")) {
                        String value = record.get(column);
                        features.put(column, value.isEmpty() ? 0.0 : Double.valueOf(value));
                    }
                }
                Map<String, Object> snapshot = new LinkedHashMap<>();
                snapshot.put("entityType", entityType);
                snapshot.put("entityId", entityId);
                snapshot.put("asOfTime", asOfTime);
                snapshot.put("features", features);
                redisTemplate.opsForValue().set(
                        String.format("feature:%s:{%s}", entityType, entityId),
                        snapshot);
                count++;
            }
        } catch (IOException | NumberFormatException e) {
            throw new RuntimeException("invalid feature snapshot " + path, e);
        }
        log.info("init {} feature snapshots finished: {} rows", entityType, count);
    }
}
