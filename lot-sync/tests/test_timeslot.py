from lot_sync.timeslot import is_timeslot_name, month_of_timeslot


def test_month_comes_from_the_name():
    assert month_of_timeslot("20261103-112600") == "202611"
    assert month_of_timeslot("exp_20260801-123000") == "202608"


def test_impossible_date_has_no_month():
    assert month_of_timeslot("20261399-000000") is None


def test_only_names_ending_in_a_timeslot_match():
    assert is_timeslot_name("20261103-112600")
    assert not is_timeslot_name("20261103-112600.tar")
    assert not is_timeslot_name("202611")


def test_lrf_month_comes_from_the_date_in_the_name():
    from lot_sync.timeslot import month_of_lrf_name
    assert month_of_lrf_name("LOTAAAA0001-20260911-172530.lrf") == "202609"
    assert month_of_lrf_name("LOTAAAA0001-20260911-172530_filtered.lrf") == "202609"
    assert month_of_lrf_name("LOTBBBB0002-20260910-164102_pub.lrf") == "202609"


def test_lrf_name_without_a_real_date_has_no_month():
    from lot_sync.timeslot import month_of_lrf_name
    assert month_of_lrf_name("report.lrf") is None
    assert month_of_lrf_name("A-20261399-120000.lrf") is None
    assert month_of_lrf_name("A-20260911-172530.txt") is None
