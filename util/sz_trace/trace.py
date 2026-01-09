# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from collections import defaultdict
import re
from perfetto.protos.perfetto.trace import perfetto_trace_pb2

"""
This module allows to create Perfetto traces for Schnizo.
Each functional unit (FU) is represented by a track where we distinguish
between regular execution and FREP execution.
During FREP the instructions are mapped to the producer IDs.

Required data structures from external:
- all_tracks: A default dict holding all tracks. Indexed by the fu_string
  and/or the instruction count.
- inflight_tracks: A default dict holding a deque for each track/event which
  is currently inflight.
"""


ROOT_TRACK_NAME = "Instructions"
ROOT_TRACK_ID = 10

TRUSTED_PKG_SEQ_ID = 22222  # A random number which must be used for all events in the trace.

# All tracks' uuids are defined by the following scheme:
# all_uuids = {
#     ALU_TYPE_NAME         : ALU_TYPE_ID,  # ALU
#     ALU_TYPE_NAME + "0"   : ALU_TYPE_ID + 1 * FU_OFFSET,  # ALU0
#     ALU_TYPE_NAME + "1"   : ALU_TYPE_ID + 2 * FU_OFFSET,  # ALU1
#     ALU_TYPE_NAME + "2"   : ALU_TYPE_ID + 3 * FU_OFFSET,  # ALU2
#     ALU_TYPE_NAME + "3"   : ALU_TYPE_ID + 4 * FU_OFFSET,  # ALU3
#     ALU_TYPE_NAME + "4"   : ALU_TYPE_ID + 5 * FU_OFFSET,  # ALU4
# }

FU_ALU = "ALU"
FU_LSU = "LSU"
FU_FPU = "FPU"
FU_CSR = "CSR"
FU_ACC = "ACC"
FU_NONE = "NONE"

# DANGER: The tracks uuid can collide after
# - 99 FUs per FU type.
# This should never be reached in practice.
# Each instruction gets an unique number starting at 10'000'000 (INSTR_OFFSET).
# The lower digits of the number are used to identify the FU Types and FU IDs.
# A track for an instruction thus resembles like:
# 10000000 * instr_number + <FU type + FU ID>
# This allows to capture more than 100'000'000'000 instructions in a trace.
FU_TYPE_OFFSET = {
    FU_ALU:     1000000,
    FU_LSU:     2000000,
    FU_FPU:     3000000,
    FU_CSR:     4000000,
    FU_ACC:     5000000,
    FU_NONE:    6000000,
}
FU_ID_OFFSET =    10000  # noqa: E222
INSTR_OFFSET = 10000000


# Returns the fu_type, fu_id and slot_id defined by the fu_string
# The fu_string must be of one of the formats:
# ALU     <-- FU type only
# ALUX    <-- FU ID (X)
# ALUX.Y  <-- FU ID (X) + Slot ID (Y)
#
# Returns None for the fields not defined
def extract_fu_details(fu_string):
    # check with regex:
    # - if it is only a string without numbers (e.g., "ALU", "LSU", "FPU"). This is the fu_type.
    # - if it is a string with a number at the end  (e.g. "ALU0", "ALU4", "LSU2"). This is the
    #   fu_type with the fu_id.
    # - if it is a with a number, a dot and another number (e.g., "ALU0.0", "FPU2.34"). This is
    #   the fu_type with the fu_id and the slot_id.
    # Return the fu_type, fu_id and slot_id

    # Define regex patterns
    fu_type_pattern = r"^[A-Za-z]+$"
    fu_id_pattern = r"^([A-Za-z]+)(\d+)$"
    fu_slot_pattern = r"^([A-Za-z]+)(\d+)\.(\d+)$"

    fu_type, fu_id, slot_id = None, None, None

    # Match the string against the patterns
    if re.match(fu_type_pattern, fu_string):
        fu_type = fu_string
    elif match := re.match(fu_id_pattern, fu_string):
        fu_type, fu_id = match.groups()
        fu_id = int(fu_id)
    elif match := re.match(fu_slot_pattern, fu_string):
        fu_type, fu_id, slot_id = match.groups()
        fu_id = int(fu_id)
        slot_id = int(slot_id)
    else:
        raise ValueError(f"Invalid FU string format to extract details: {fu_string}")

    return fu_type, fu_id, slot_id


def get_root_track(all_tracks):
    if (ROOT_TRACK_NAME not in all_tracks):
        root_track = perfetto_trace_pb2.TracePacket()
        root_track.track_descriptor.uuid = ROOT_TRACK_ID
        root_track.track_descriptor.name = ROOT_TRACK_NAME
        all_tracks[ROOT_TRACK_NAME] = root_track
    return all_tracks[ROOT_TRACK_NAME]


# Returns the corresponding track if it exists in the all_tracks dictionary. If the track
# does not exist, it creates a new one and links it to its parents.
# This function gets called recursively to create the full hierarchy of tracks.
def get_track(fu_string, all_tracks):
    # Normalize fu_string so all slots share the same track
    fu_type, fu_id, slot_id = extract_fu_details(fu_string)
    if slot_id is not None:
        fu_string = f"{fu_type}{fu_id}"

    # Return the track if it already exists. This is required for recursive calls.
    if (fu_string in all_tracks):
        return all_tracks[fu_string]

    # Check if the root track exists. This must be called at least once. For simplicity we check it
    # each time.
    get_root_track(all_tracks)

    # Create a new track for the desired fu_string
    fu_type, fu_id, _ = extract_fu_details(fu_string)

    if (fu_type not in FU_TYPE_OFFSET):
        raise ValueError(
            f"Invalid FU type: {fu_type}. "
            f"Must be one of {list(FU_TYPE_OFFSET.keys())}"
        )

    # Create a unified track for both type-only (e.g., ACC) and type+ID (e.g., ALU0) FUs
    # For type-only, use ID 0; for type+ID, use the actual ID
    fu_id_for_uuid = fu_id if fu_id is not None else 0
    uuid = FU_TYPE_OFFSET[fu_type] + (fu_id_for_uuid + 1) * FU_ID_OFFSET

    new_track = perfetto_trace_pb2.TracePacket()
    new_track.track_descriptor.uuid = uuid
    new_track.track_descriptor.parent_uuid = ROOT_TRACK_ID
    new_track.track_descriptor.name = fu_string  # Use the full string (e.g., "ACC" or "ALU0")
    ordering = perfetto_trace_pb2.TrackDescriptor.ChildTracksOrdering
    new_track.track_descriptor.child_ordering = ordering.LEXICOGRAPHIC
    all_tracks[fu_string] = new_track
    return all_tracks[fu_string]


# Returns a starting slice event for the given fu_string at the given time.
def start_instr(fu_string, instr_name, time_ns, all_tracks, inflight_tracks):
    # Normalize slot-specific tracks to the FU-id track so all slots share one track.
    _, _, slot_id = extract_fu_details(fu_string)

    # Get the hierarchical track for each FU
    track = get_track(fu_string, all_tracks)

    # Create a new track for each instruction to allow non perfectly nested events.
    # This new track has the parent set to the hierarchical track we want to use but a different
    # uuid. The name must also match that Perfetto UI merges the tracks.
    # The uuid of the "instruction track" must be unique in the whole trace.
    # See https://perfetto.dev/docs/reference/synthetic-track-event#process-scoped-async-slices
    # This link points to process-scoped async slices but the nesting work the same way for
    # custom scoped slices.

    # The unique uuid for this instruction is based upon the parent uuid and a global instruction
    # counter. However, to keep the global counter stateless, we simply use the count of total
    # tracks. This does not perfectly reflect the number of instructions as the hierarchical tracks
    # are additionally counted. And we also waste a lot of uuids because we could count for each FU
    # separately. The maximal number of instructions is however way beyond what we need (see above).
    instr_count = len(all_tracks)
    instr_uuid = (INSTR_OFFSET * instr_count) + track.track_descriptor.uuid
    instr_track = perfetto_trace_pb2.TracePacket()
    instr_track.track_descriptor.uuid = instr_uuid
    # skip the hierarchical track and use the parent directly (less clutter in UI).
    instr_track.track_descriptor.parent_uuid = track.track_descriptor.parent_uuid
    instr_track.track_descriptor.name = track.track_descriptor.name
    all_tracks[f"{track.track_descriptor.name}-{instr_track.track_descriptor.uuid}"] = instr_track

    # We must keep track of the uuid of the event we started to end it later. We assign it to a
    # dict with a deque indexed by the hierarchical track uuid.
    inflight_tracks[track.track_descriptor.uuid].appendleft(instr_track.track_descriptor.uuid)

    event = perfetto_trace_pb2.TracePacket()
    event.timestamp = time_ns
    event.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_BEGIN
    event.track_event.track_uuid = instr_track.track_descriptor.uuid
    event.track_event.name = instr_name
    if slot_id is not None:
        annotation = event.track_event.debug_annotations.add()
        annotation.name = "slot_id"
        annotation.int_value = slot_id
    event.trusted_packet_sequence_id = TRUSTED_PKG_SEQ_ID

    return event


# Returns an ending slice event for the given fu_string at the given time.
def end_instr(fu_string, time_ns, all_tracks, inflight_tracks):
    # Normalize slot-specific tracks to the FU-id track so all slots share one track.
    fu_type, fu_id, slot_id = extract_fu_details(fu_string)
    if slot_id is not None:
        fu_string = f"{fu_type}{fu_id}"

    track = get_track(fu_string, all_tracks)

    # Get the track uuid from the oldest instruction on this track.
    instr_uuid = inflight_tracks[track.track_descriptor.uuid].pop()

    event = perfetto_trace_pb2.TracePacket()
    event.timestamp = time_ns
    event.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_END
    event.track_event.track_uuid = instr_uuid
    event.trusted_packet_sequence_id = TRUSTED_PKG_SEQ_ID

    return event


# Perfetto always sets the time to 0 for the first event. We want consistency with the simulation
# time. Therefore, we create an artificial slice starting at simulation time 0.
def add_start_offset(all_tracks):
    # Use the NONE track for the start offset event
    none_track = get_track(FU_NONE, all_tracks)

    start_event = perfetto_trace_pb2.TracePacket()
    start_event.timestamp = 0
    start_event.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_INSTANT
    start_event.track_event.track_uuid = none_track.track_descriptor.uuid
    start_event.track_event.name = "Start offset (cycle count synchronization)"
    start_event.trusted_packet_sequence_id = TRUSTED_PKG_SEQ_ID

    return start_event


def create(all_tracks, events):
    trace = perfetto_trace_pb2.Trace()
    # Combine the all_tracks packets and events into a single trace.
    trace.packet.extend(list(all_tracks.values()))
    trace.packet.extend(events)
    return trace


# Expects an open file to write into. Must be opened in "wb" mode.
def write_to_file(trace, file):
    file.write(trace.SerializeToString())


def test():
    all_tracks = defaultdict()
    # Create some events for some FUs
    events = [
        start_instr("ALU0", "ADD", 100, all_tracks),
        end_instr("ALU0", 150, all_tracks),
        start_instr("ALU0.0", "SUB", 200, all_tracks),
        end_instr("ALU0.0", 250, all_tracks),
        start_instr("FPU2.1", "DIV", 400, all_tracks),
        end_instr("FPU2.1", 450, all_tracks),
        start_instr("FPU0.1", "DIV", 450, all_tracks),
        end_instr("FPU0.1", 500, all_tracks),
        start_instr("LSU3.2", "LOAD", 500, all_tracks),
        end_instr("LSU3.2", 550, all_tracks),
    ]

    trace = create(all_tracks, events)

    # Serialize the trace to a file
    with open("example.pb", "wb") as f:
        write_to_file(trace, f)


# An example how to create synthetic traces including non perfectly nested events.
def perfetto_protobuf_example():
    # Create the root packet
    root_packet = perfetto_trace_pb2.TracePacket()
    root_descriptor = root_packet.track_descriptor
    root_descriptor.uuid = 48948
    root_descriptor.name = "Root"

    # Create Parent A packet
    parent_a_packet = perfetto_trace_pb2.TracePacket()
    parent_a_descriptor = parent_a_packet.track_descriptor
    parent_a_descriptor.uuid = 50000
    parent_a_descriptor.parent_uuid = 48948
    parent_a_descriptor.name = "Parent A"

    # Create Parent B packet
    parent_b_packet = perfetto_trace_pb2.TracePacket()
    parent_b_descriptor = parent_b_packet.track_descriptor
    parent_b_descriptor.uuid = 50001
    parent_b_descriptor.parent_uuid = 48948
    parent_b_descriptor.name = "Parent B"

    # Create Child A1 packet
    child_a1_packet = perfetto_trace_pb2.TracePacket()
    child_a1_descriptor = child_a1_packet.track_descriptor
    child_a1_descriptor.uuid = 60000
    child_a1_descriptor.parent_uuid = 50000
    child_a1_descriptor.name = "Child A1"

    # Create Child A2 packet
    child_a2_packet = perfetto_trace_pb2.TracePacket()
    child_a2_descriptor = child_a2_packet.track_descriptor
    child_a2_descriptor.uuid = 60001
    child_a2_descriptor.parent_uuid = 50000
    child_a2_descriptor.name = "Child A2"

    # Create Child B1 packet
    child_b1_packet = perfetto_trace_pb2.TracePacket()
    child_b1_descriptor = child_b1_packet.track_descriptor
    child_b1_descriptor.uuid = 70000
    child_b1_descriptor.parent_uuid = 50001
    child_b1_descriptor.name = "Child B1"

    # Create non nested event for B1
    nonnest_b1_packet = perfetto_trace_pb2.TracePacket()
    nonnest_b1_descriptor = nonnest_b1_packet.track_descriptor
    nonnest_b1_descriptor.uuid = 70001
    nonnest_b1_descriptor.parent_uuid = 50001
    nonnest_b1_descriptor.name = "Child B1"  # Same name as B1

    # Create non nested event for B1 #2
    nonnest2_b1_packet = perfetto_trace_pb2.TracePacket()
    nonnest2_b1_descriptor = nonnest2_b1_packet.track_descriptor
    nonnest2_b1_descriptor.uuid = 70002
    nonnest2_b1_descriptor.parent_uuid = 50001
    nonnest2_b1_descriptor.name = "Child B1"  # Same name as B1

    # EVENTS

    # Create events for Child A1
    event_a1_begin = perfetto_trace_pb2.TracePacket()
    event_a1_begin.timestamp = 200
    event_a1_begin.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_BEGIN
    event_a1_begin.track_event.track_uuid = 60000
    event_a1_begin.track_event.name = "A1"
    event_a1_begin.trusted_packet_sequence_id = 3903809

    event_a1_end = perfetto_trace_pb2.TracePacket()
    event_a1_end.timestamp = 250
    event_a1_end.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_END
    event_a1_end.track_event.track_uuid = 60000
    event_a1_end.trusted_packet_sequence_id = 3903809

    # Create events for Child A2
    event_a2_begin = perfetto_trace_pb2.TracePacket()
    event_a2_begin.timestamp = 220
    event_a2_begin.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_BEGIN
    event_a2_begin.track_event.track_uuid = 60001
    event_a2_begin.track_event.name = "A2"
    event_a2_begin.trusted_packet_sequence_id = 3903809

    event_a2_end = perfetto_trace_pb2.TracePacket()
    event_a2_end.timestamp = 240
    event_a2_end.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_END
    event_a2_end.track_event.track_uuid = 60001
    event_a2_end.trusted_packet_sequence_id = 3903809

    # Create events for Child B1
    event_b1_begin = perfetto_trace_pb2.TracePacket()
    event_b1_begin.timestamp = 210
    event_b1_begin.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_BEGIN
    event_b1_begin.track_event.track_uuid = 70000
    event_b1_begin.track_event.name = "B1"
    event_b1_begin.trusted_packet_sequence_id = 3903809

    event_b1_end = perfetto_trace_pb2.TracePacket()
    event_b1_end.timestamp = 230
    event_b1_end.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_END
    event_b1_end.track_event.track_uuid = 70000
    event_b1_end.trusted_packet_sequence_id = 3903809

    # Create events for Child B1 nonnested
    event_b1_nonnest_begin = perfetto_trace_pb2.TracePacket()
    event_b1_nonnest_begin.timestamp = 220
    event_b1_nonnest_begin.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_BEGIN
    event_b1_nonnest_begin.track_event.track_uuid = 70001
    event_b1_nonnest_begin.track_event.name = "B1 nonnested"
    event_b1_nonnest_begin.trusted_packet_sequence_id = 3903809

    event_b1_nonnest_end = perfetto_trace_pb2.TracePacket()
    event_b1_nonnest_end.timestamp = 240
    event_b1_nonnest_end.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_END
    event_b1_nonnest_end.track_event.track_uuid = 70001
    event_b1_nonnest_end.trusted_packet_sequence_id = 3903809

    # Create events for Child B1 nonnested
    event_b1_2_nonnest_begin = perfetto_trace_pb2.TracePacket()
    event_b1_2_nonnest_begin.timestamp = 232
    event_b1_2_nonnest_begin.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_BEGIN
    event_b1_2_nonnest_begin.track_event.track_uuid = 70002
    event_b1_2_nonnest_begin.track_event.name = "B1 nonnested 2"
    event_b1_2_nonnest_begin.trusted_packet_sequence_id = 3903809

    event_b1_2_nonnest_end = perfetto_trace_pb2.TracePacket()
    event_b1_2_nonnest_end.timestamp = 238
    event_b1_2_nonnest_end.track_event.type = perfetto_trace_pb2.TrackEvent.TYPE_SLICE_END
    event_b1_2_nonnest_end.track_event.track_uuid = 70002
    event_b1_2_nonnest_end.trusted_packet_sequence_id = 3903809

    # Combine all packets into a trace
    trace = perfetto_trace_pb2.Trace()
    trace.packet.extend([
        root_packet,
        parent_a_packet,
        parent_b_packet,
        child_a1_packet,
        child_a2_packet,
        child_b1_packet,
        nonnest_b1_packet,
        nonnest2_b1_packet,
        event_a1_begin,
        event_a1_end,
        event_a2_begin,
        event_a2_end,
        event_b1_begin,
        event_b1_end,
        event_b1_nonnest_begin,
        event_b1_nonnest_end,
        event_b1_2_nonnest_begin,
        event_b1_2_nonnest_end,
    ])

    # Serialize the trace to a file
    with open("trace.pb", "wb") as f:
        f.write(trace.SerializeToString())


if __name__ == '__main__':
    perfetto_protobuf_example()
