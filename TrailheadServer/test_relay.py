import unittest
from relay import RelayStore


class RelayTests(unittest.TestCase):
    def test_append_only_and_hazards(self):
        store = RelayStore(":memory:")
        store.save_trip({"tripID": "trip", "groupName": "Crew", "contactName": "A",
                         "contactEmail": "a@example.com", "expectedReturn": "2030-01-01T00:00:00Z"})
        event = {"id": "one", "tripID": "trip", "deviceID": "phone", "type": "sos",
                 "recordedAt": "2030-01-01T00:00:00Z", "payload": {"injuries": "ankle"}}
        self.assertEqual(store.save_events([event, event]), 1)
        self.assertEqual(store.save_events([{**event, "payload": {"injuries": "changed"}}]), 0)
        trips, events = store.snapshot()
        self.assertEqual(len(trips), 1)
        self.assertEqual(events[0]["payload"]["injuries"], "ankle")
        store.add_hazard({"id": "bridge", "message": "Bridge out"})
        self.assertEqual(store.hazards()[0]["message"], "Bridge out")


if __name__ == "__main__":
    unittest.main()
