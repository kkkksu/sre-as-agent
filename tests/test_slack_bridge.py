import unittest

from sre_as_agent.slack_bridge import (
    BridgeConfig,
    alert_from_slack_body,
    build_kagent_prompt,
    extract_a2a_text,
    extract_session_result_text,
    parse_alert_marker,
    parse_datadog_link_marker,
    should_process_alert,
)


class SlackBridgeTests(unittest.TestCase):
    def config(self) -> BridgeConfig:
        return BridgeConfig(
            slack_bot_token="test-slack-bot-token",
            slack_app_token="test-slack-app-token",
            kagent_bot_user_id="U_KAGENT",
            allowed_channel_ids={"C_ALERTS"},
            trusted_datadog_sender_ids=set(),
            kagent_base_url="https://kagent.example.com",
            kagent_api_token="token",
        )

    def test_alert_from_slack_body_uses_message_ts_as_default_thread(self) -> None:
        alert = alert_from_slack_body(
            {
                "event_id": "Ev1",
                "event": {
                    "type": "message",
                    "channel": "C_ALERTS",
                    "ts": "1710000000.123",
                    "text": "<@U_KAGENT> investigate",
                },
            }
        )

        self.assertIsNotNone(alert)
        assert alert is not None
        self.assertEqual(alert.thread_ts, "1710000000.123")

    def test_should_process_only_allowlisted_mentioned_messages(self) -> None:
        alert = alert_from_slack_body(
            {
                "event_id": "Ev1",
                "event": {
                    "type": "message",
                    "channel": "C_ALERTS",
                    "ts": "1710000000.123",
                    "text": "Datadog alert <@U_KAGENT>",
                    "bot_id": "B_DATADOG",
                },
            }
        )

        self.assertIsNotNone(alert)
        assert alert is not None
        self.assertTrue(should_process_alert(alert, self.config()))

    def test_should_process_datadog_marker_without_kagent_mention(self) -> None:
        alert = alert_from_slack_body(
            {
                "event_id": "Ev1",
                "event": {
                    "type": "message",
                    "channel": "C_ALERTS",
                    "ts": "1710000000.123",
                    "text": (
                        "Datadog alert\n\n"
                        '```json\n{"source":"datadog","alert_id":"123","monitor_id":"456",'
                        '"dedupe_key":"datadog:123"}\n```'
                    ),
                    "bot_id": "B_DATADOG",
                },
            }
        )

        self.assertIsNotNone(alert)
        assert alert is not None
        self.assertTrue(should_process_alert(alert, self.config()))
        self.assertEqual(alert.dedupe_key, "datadog:123")

    def test_should_process_datadog_attachment_without_top_level_text(self) -> None:
        alert = alert_from_slack_body(
            {
                "event_id": "Ev1",
                "event": {
                    "type": "message",
                    "channel": "C_ALERTS",
                    "ts": "1710000000.123",
                    "text": "",
                    "bot_id": "B_DATADOG",
                    "attachments": [
                        {
                            "title": "Triggered: CPU usage is high",
                            "title_link": (
                                "https://app.datadoghq.eu/monitors/107666844?"
                                "event_id=8673998524189468284&link_monitor_id=107666844&"
                                "link_event_id=8673998524189468284&link_event_ts=1781273466"
                            ),
                            "text": "@slack-monitor-sre-as-agent\n\nHigh CPU usage detected.",
                        }
                    ],
                },
            }
        )

        self.assertIsNotNone(alert)
        assert alert is not None
        self.assertTrue(should_process_alert(alert, self.config()))
        self.assertEqual(alert.dedupe_key, "datadog:8673998524189468284")
        self.assertIn("High CPU usage detected", alert.text)

    def test_should_ignore_datadog_marker_from_untrusted_sender_when_configured(self) -> None:
        alert = alert_from_slack_body(
            {
                "event_id": "Ev1",
                "event": {
                    "type": "message",
                    "channel": "C_ALERTS",
                    "ts": "1710000000.123",
                    "text": '{"source":"datadog","alert_id":"123"}',
                    "bot_id": "B_UNKNOWN",
                },
            }
        )
        config = BridgeConfig(
            slack_bot_token="test-slack-bot-token",
            slack_app_token="test-slack-app-token",
            kagent_bot_user_id="U_KAGENT",
            allowed_channel_ids={"C_ALERTS"},
            trusted_datadog_sender_ids={"B_DATADOG"},
            kagent_base_url="https://kagent.example.com",
            kagent_api_token="token",
        )

        self.assertIsNotNone(alert)
        assert alert is not None
        self.assertFalse(should_process_alert(alert, config))

    def test_should_ignore_non_allowlisted_channels(self) -> None:
        alert = alert_from_slack_body(
            {
                "event_id": "Ev1",
                "event": {
                    "type": "message",
                    "channel": "C_OTHER",
                    "ts": "1710000000.123",
                    "text": "Datadog alert <@U_KAGENT>",
                },
            }
        )

        self.assertIsNotNone(alert)
        assert alert is not None
        self.assertFalse(should_process_alert(alert, self.config()))

    def test_prompt_contains_slack_context_and_read_only_instruction(self) -> None:
        alert = alert_from_slack_body(
            {
                "event_id": "Ev1",
                "event": {
                    "type": "message",
                    "channel": "C_ALERTS",
                    "ts": "1710000000.123",
                    "thread_ts": "1710000000.000",
                    "text": "CPU high <@U_KAGENT>",
                },
            }
        )

        self.assertIsNotNone(alert)
        assert alert is not None
        prompt = build_kagent_prompt(alert)
        self.assertIn("untrusted data", prompt)
        self.assertIn("perform mutating actions", prompt)
        self.assertIn("C_ALERTS", prompt)
        self.assertIn("CPU high", prompt)

    def test_prompt_contains_datadog_marker_context(self) -> None:
        alert = alert_from_slack_body(
            {
                "event_id": "Ev1",
                "event": {
                    "type": "message",
                    "channel": "C_ALERTS",
                    "ts": "1710000000.123",
                    "text": '{"source":"datadog","alert_id":"123","monitor_id":"456"}',
                },
            }
        )

        self.assertIsNotNone(alert)
        assert alert is not None
        prompt = build_kagent_prompt(alert)
        self.assertIn("alert_id: 123", prompt)
        self.assertIn("monitor_id: 456", prompt)
        self.assertIn("fetch the alert and monitor details", prompt)

    def test_parse_alert_marker_from_inline_json(self) -> None:
        marker = parse_alert_marker('alert {"source":"datadog","alert_id":"123"}')

        self.assertIsNotNone(marker)
        assert marker is not None
        self.assertEqual(marker.alert_id, "123")

    def test_parse_datadog_link_marker(self) -> None:
        marker = parse_datadog_link_marker(
            "https://app.datadoghq.eu/monitors/107666844?"
            "group=host%3Ahost.name&event_id=8673998524189468284&"
            "link_monitor_id=107666844&link_event_id=8673998524189468284&"
            "link_event_ts=1781273466"
        )

        self.assertIsNotNone(marker)
        assert marker is not None
        self.assertEqual(marker.alert_id, "8673998524189468284")
        self.assertEqual(marker.monitor_id, "107666844")
        self.assertEqual(marker.dedupe_key, "datadog:8673998524189468284")

    def test_extract_a2a_text_from_task_history(self) -> None:
        payload = {
            "result": {
                "history": [
                    {"role": "user", "parts": [{"text": "alert"}]},
                    {"role": "agent", "parts": [{"text": "likely cause found"}]},
                ]
            }
        }

        self.assertEqual(extract_a2a_text(payload), "likely cause found")

    def test_extract_session_result_text_from_model_event(self) -> None:
        payload = {
            "data": {
                "events": [
                    {
                        "data": (
                            '{"content":{"role":"model","parts":'
                            '[{"text":"investigation summary"}]}}'
                        )
                    }
                ]
            }
        }

        self.assertEqual(extract_session_result_text(payload), "investigation summary")

    def test_extract_session_result_text_from_ask_user_event(self) -> None:
        payload = {
            "data": {
                "events": [
                    {
                        "data": {
                            "content": {
                                "role": "model",
                                "parts": [
                                    {
                                        "function_call": {
                                            "name": "ask_user",
                                            "args": {
                                                "questions": [
                                                    {
                                                        "question": (
                                                            "No checkout/default telemetry was found. "
                                                            "Please confirm the service and environment."
                                                        )
                                                    }
                                                ]
                                            },
                                        }
                                    }
                                ],
                            }
                        }
                    }
                ]
            }
        }

        self.assertEqual(
            extract_session_result_text(payload),
            (
                "kagent needs more context:\n\n"
                "No checkout/default telemetry was found. Please confirm the service and environment."
            ),
        )


if __name__ == "__main__":
    unittest.main()
