import unittest
from guardian import GuardianStore, process_pending


class GuardianTests(unittest.TestCase):
    def setUp(self):
        self.store = GuardianStore()
        self.store.add_trip({"tripID": "trip", "expectedReturn": 1000,
                             "groupName": "Hikers", "contactName": "Casey", "contactEmail": "casey@example.test"})

    def test_overdue_is_deterministic_and_once_only(self):
        self.assertEqual(self.store.queue_overdue(now=2799), 0)
        self.assertEqual(self.store.queue_overdue(now=2800), 1)
        self.assertEqual(self.store.queue_overdue(now=3000), 0)

    def test_check_in_prevents_overdue(self):
        self.store.add_events([self.event("check", "checked_in")])
        self.assertEqual(self.store.queue_overdue(now=3000), 0)

    def test_sos_deduplicates_and_sends_once(self):
        event = self.event("sos-id", "sos")
        self.assertEqual(self.store.add_events([event, event]), 1)
        calls = []
        process_pending(self.store, lambda facts: "Packet: " + facts["reason"],
                        lambda email, packet, key: calls.append((email, packet, key)))
        self.assertEqual(calls, [("casey@example.test", "Packet: sos", "sos:sos-id")])
        process_pending(self.store, lambda _: "again", lambda *args: calls.append(args))
        self.assertEqual(len(calls), 1)

    @staticmethod
    def event(id, type):
        return {"id": id, "tripID": "trip", "deviceID": "device", "type": type,
                "recordedAt": 1001, "payload": {"value": "test"}}


if __name__ == "__main__":
    unittest.main()
