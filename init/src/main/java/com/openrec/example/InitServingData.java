package com.openrec.example;

import com.openrec.example.task.*;
import lombok.extern.slf4j.Slf4j;
import java.util.ArrayList;
import java.util.List;

/** Selects and executes the serving-data bootstrap chain for a deployment mode. */
@Slf4j
public final class InitServingData {
    private InitServingData() {
    }

    public static List<InitTask> standaloneTasks() {
        return List.of(
                new RedisUserTask(),
                new RedisItemTask(),
                new RedisEventTask(),
                new RedisFeatureTask("user"),
                new RedisFeatureTask("item"),
                new RecallTableTask("hot", "recall/item/hot.csv"),
                new RecallTableTask("new", "recall/item/new.csv"),
                new RecallTableTask("item-cf-i2i", "recall/item/item_cf_i2i.csv"),
                new RecallTableTask("content-i2i", "recall/item/content_i2i.csv"),
                new RecallTableTask("user-cf-u2i", "recall/item/user_cf_u2i.csv"),
                new RecallTableTask("user-cf-u2u", "recall/user/user_cf_u2u.csv"),
                new RecallTableTask("content-u2u", "recall/user/content_u2u.csv"),
                new RecallTableTask("user-als-u2u", "recall/user/user_als_u2u.csv"),
                new SearchIndexTask("item"),
                new SearchIndexTask("user"),
                new SequenceEmbeddingTask());
    }

    public static List<InitTask> clusterTasks() {
        // Cluster also needs an initial online snapshot before asynchronous projections run.
        // Keep its composition explicit so future cluster-only imports do not affect standalone.
        return List.of(
                new RedisUserTask(),
                new RedisItemTask(),
                new RedisEventTask(),
                new RedisFeatureTask("user"),
                new RedisFeatureTask("item"),
                new RecallTableTask("hot", "recall/item/hot.csv"),
                new RecallTableTask("new", "recall/item/new.csv"),
                new RecallTableTask("item-cf-i2i", "recall/item/item_cf_i2i.csv"),
                new RecallTableTask("content-i2i", "recall/item/content_i2i.csv"),
                new RecallTableTask("user-cf-u2i", "recall/item/user_cf_u2i.csv"),
                new RecallTableTask("user-cf-u2u", "recall/user/user_cf_u2u.csv"),
                new RecallTableTask("content-u2u", "recall/user/content_u2u.csv"),
                new RecallTableTask("user-als-u2u", "recall/user/user_als_u2u.csv"),
                new SearchIndexTask("item"),
                new SearchIndexTask("user"),
                new SequenceEmbeddingTask());
    }

    public static List<InitTask> tasks(InitOptions options) {
        List<InitTask> selected = new ArrayList<>(switch (options.mode()) {
            case STANDALONE -> standaloneTasks();
            case CLUSTER -> clusterTasks();
        });
        if (options.languageEmbeddingEnabled()) {
            selected.add(new LanguageEmbeddingTask());
        }
        selected.add(0, new ValidateInputsTask(selected));
        return List.copyOf(selected);
    }

    public static void run(InitContext context, List<InitTask> tasks) {
        for (InitTask task : tasks) {
            log.info("initialization task started: {}", task.name());
            try {
                task.execute(context);
            } catch (Exception error) {
                throw new IllegalStateException("initialization task failed: " + task.name(), error);
            }
            log.info("initialization task completed: {}", task.name());
        }
    }

    public static void main(String[] args) throws Exception {
        InitOptions options = InitOptions.parse(args);
        log.info("initializing {} serving data from {}", options.mode(), options.dataDir());
        try (InitContext context = new InitContext(options)) {
            run(context, tasks(options));
        }
    }
}
