CREATE TABLE `activity_spans` (
	`id` text PRIMARY KEY NOT NULL,
	`session_id` text NOT NULL,
	`kind` text NOT NULL,
	`app_bundle_id` text,
	`app_name` text,
	`window_title` text,
	`url_host` text,
	`url_path` text,
	`started_at` integer NOT NULL,
	`ended_at` integer NOT NULL,
	`was_blocked` integer DEFAULT false NOT NULL,
	FOREIGN KEY (`session_id`) REFERENCES `sessions`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `spans_session` ON `activity_spans` (`session_id`);--> statement-breakpoint
CREATE TABLE `sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`category_id` text,
	`source` text NOT NULL,
	`todoist_task_id` text,
	`entry_id` text,
	`title_snapshot` text NOT NULL,
	`planned_seconds` integer NOT NULL,
	`actual_seconds` integer NOT NULL,
	`started_at` integer NOT NULL,
	`ended_at` integer NOT NULL,
	`status` text DEFAULT 'completed' NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`category_id`) REFERENCES `categories`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`entry_id`) REFERENCES `entries`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `sessions_user_started` ON `sessions` (`user_id`,`started_at`);