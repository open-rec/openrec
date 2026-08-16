package com.openrec.example.web;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * A small visual demo of open-rec: browse items across four recall tabs, feed behaviour back to
 * rec-server through rec-client, and see the recommendations change on the next refresh.
 */
@SpringBootApplication
public class WebApplication {

    public static void main(String[] args) {
        SpringApplication.run(WebApplication.class, args);
    }
}
