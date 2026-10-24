extends "res://tests/test_base.gd"

const TimeSystem := preload("res://sim/env/time_system.gd")


func _time(overrides: Dictionary = {}) -> RefCounted:
	var t := TimeSystem.new()
	t.setup(make_params("", overrides))
	return t


func test_calendar_mapping() -> void:
	var t := _time({"time.ticks_per_hour": 4, "time.hours_per_day": 24, "time.days_per_season": 20})
	check_eq(t.ticks_per_day, 96, "ticks per day")
	check_eq(t.ticks_per_season, 1920, "ticks per season")
	check_eq(t.ticks_per_year, 7680, "ticks per year")
	check_eq([t.year(0), t.season(0), t.day(0), t.hour(0)], [0, 0, 0, 0], "tick 0 = year 0, spring, day 0, midnight")
	check_eq(t.hour(95), 23, "last tick of day 0 is hour 23")
	check_eq(t.minute(95), 45, "and minute 45")
	check_eq(t.day(96), 1, "tick 96 starts day 1")
	check_eq(t.season(1919), 0, "last tick of spring")
	check_eq(t.season(1920), 1, "first tick of summer")
	check_eq(t.season(3 * 1920), 3, "winter")
	check_eq([t.year(7680), t.season(7680)], [1, 0], "next year's spring")
	check_eq(t.season_count(7680 + 1920), 5, "absolute season counter")
	check_eq(t.describe(7680 + 1920 + 96 * 2 + 4 * 13 + 2), "Year 2, Summer day 3, 13:30", "describe")


func test_daylight_follows_day_and_season() -> void:
	var t := _time()
	var noon: int = t.ticks_per_day / 2
	check_eq(t.daylight(noon), 1.0, "noon is full daylight")
	check_eq(t.daylight(0), t.night_light, "midnight is night light")
	var summer_light := 0
	var winter_light := 0
	for i in t.ticks_per_day:
		var v: float = t.daylight(t.ticks_per_season + i)
		check(v >= t.night_light and v <= 1.0, "daylight within [night_light, 1]")
		if v > 0.5:
			summer_light += 1
		if t.daylight(3 * t.ticks_per_season + i) > 0.5:
			winter_light += 1
	check(summer_light > winter_light, "summer days are longer (%d vs %d ticks)" % [summer_light, winter_light])
	var expected := roundi(t.daylight_share[1] * t.ticks_per_day)
	check(absi(summer_light - expected) <= 2, "summer day length matches config (%d vs %d ticks)" % [summer_light, expected])
