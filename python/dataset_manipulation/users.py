import json
from datetime import datetime, timedelta
from typing import List, Tuple, Dict

# ---------- Helpers ----------

def to_datetime(ts: str) -> datetime:
    """Convert ISO string to datetime."""
    return datetime.fromisoformat(ts)

def merge_intervals(intervals: List[Tuple[datetime, datetime]]) -> List[Tuple[datetime, datetime]]:
    """Merge overlapping time intervals."""
    if not intervals:
        return []
    intervals = sorted(intervals, key=lambda x: x[0])
    merged = [intervals[0]]

    for start, end in intervals[1:]:
        last_start, last_end = merged[-1]
        if start <= last_end:  # overlap
            merged[-1] = (last_start, max(last_end, end))
        else:
            merged.append((start, end))
    return merged

def compute_total_minutes(intervals: List[Tuple[datetime, datetime]]) -> int:
    """Compute total time in minutes for a list of intervals."""
    return sum(int((end - start).total_seconds() // 60) for start, end in intervals)

def compute_average_session(intervals: List[Tuple[datetime, datetime]]) -> float:
    """Compute average session length in minutes."""
    if not intervals:
        return 0.0
    total = compute_total_minutes(intervals)
    return total / len(intervals)

def find_global_free_slots(users_intervals: List[List[Tuple[datetime, datetime]]],
                           work_start: datetime, work_end: datetime) -> List[Tuple[datetime, datetime]]:
    """Find free time slots when no user is active in the given work window."""
    # Flatten all intervals
    all_intervals = [iv for intervals in users_intervals for iv in intervals]
    merged_all = merge_intervals(all_intervals)

    free_slots = []
    prev_end = work_start
    for start, end in merged_all:
        if start > prev_end:
            free_slots.append((prev_end, start))
        prev_end = max(prev_end, end)

    if prev_end < work_end:
        free_slots.append((prev_end, work_end))

    return free_slots

# ---------- Main Logic ----------

if __name__ == "__main__":
    data = """
    {
      "users": [
        {
          "id": 1,
          "sessions": [
            {"start": "2025-10-01T09:00:00", "end": "2025-10-01T10:30:00"},
            {"start": "2025-10-01T10:15:00", "end": "2025-10-01T11:00:00"},
            {"start": "2025-10-01T13:00:00", "end": "2025-10-01T14:00:00"}
          ]
        },
        {
          "id": 2,
          "sessions": [
            {"start": "2025-10-01T09:45:00", "end": "2025-10-01T10:15:00"},
            {"start": "2025-10-01T15:00:00", "end": "2025-10-01T15:30:00"}
          ]
        }
      ]
    }
    """

    parsed = json.loads(data)

    all_users_intervals = []

    for user in parsed["users"]:
        intervals = [(to_datetime(s["start"]), to_datetime(s["end"])) for s in user["sessions"]]
        merged = merge_intervals(intervals)
        all_users_intervals.append(merged)

        total_minutes = compute_total_minutes(merged)
        avg_session = compute_average_session(merged)

        print(f"User {user['id']}:")
        print(f"  Merged sessions: {merged}")
        print(f"  Total active time: {total_minutes} minutes")
        print(f"  Average session length: {avg_session:.2f} minutes\n")

    # Workday window
    work_start = datetime.fromisoformat("2025-10-01T09:00:00")
    work_end = datetime.fromisoformat("2025-10-01T17:00:00")

    free_slots = find_global_free_slots(all_users_intervals, work_start, work_end)
    print("Global free slots:")
    for start, end in free_slots:
        print(f"  {start.time()} - {end.time()}")
