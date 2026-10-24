## In-game time, derived purely from the tick: tick -> hour -> day -> season -> year.
## Holds no state of its own, so it never needs saving and cannot drift. Tick 0 is midnight
## at the start of spring, year 0.
extends RefCounted

const SEASONS := 4
const SEASON_NAMES := ["spring", "summer", "autumn", "winter"]
const MINUTES_PER_HOUR := 60
const NOON := 0.5

var ticks_per_hour := 1
var hours_per_day := 1
var days_per_season := 1
var ticks_per_day := 1
var ticks_per_season := 1
var ticks_per_year := 1
var days_per_year := 1
## Share of the day that is daylight, per season.
var daylight_share := PackedFloat64Array()
var twilight := 0.0
var night_light := 0.0


func setup(params: RefCounted) -> void:
	ticks_per_hour = params.get_int("time.ticks_per_hour")
	hours_per_day = params.get_int("time.hours_per_day")
	days_per_season = params.get_int("time.days_per_season")
	ticks_per_day = ticks_per_hour * hours_per_day
	ticks_per_season = ticks_per_day * days_per_season
	ticks_per_year = ticks_per_season * SEASONS
	days_per_year = days_per_season * SEASONS
	daylight_share.resize(SEASONS)
	for s in SEASONS:
		daylight_share[s] = params.get_float("time.daylight." + SEASON_NAMES[s])
	twilight = params.get_float("time.twilight")
	night_light = params.get_float("time.night_light")


@warning_ignore("integer_division")
func day(tick: int) -> int:
	return tick / ticks_per_day


## Absolute season counter since tick 0 (season(tick) is this mod 4).
@warning_ignore("integer_division")
func season_count(tick: int) -> int:
	return day(tick) / days_per_season


func season(tick: int) -> int:
	return season_count(tick) % SEASONS


@warning_ignore("integer_division")
func year(tick: int) -> int:
	return tick / ticks_per_year


func day_of_season(tick: int) -> int:
	return day(tick) % days_per_season


@warning_ignore("integer_division")
func hour(tick: int) -> int:
	return (tick % ticks_per_day) / ticks_per_hour


@warning_ignore("integer_division")
func minute(tick: int) -> int:
	return (tick % ticks_per_hour) * MINUTES_PER_HOUR / ticks_per_hour


## Position within the day, 0 = midnight, 0.5 = noon.
func day_phase(tick: int) -> float:
	return float(tick % ticks_per_day) / ticks_per_day


## Day/night factor: 1 in full daylight, night_light at night, linear ramps of `twilight`
## (share of a day) centred on dawn and dusk. Day length follows the season.
func daylight(tick: int) -> float:
	var half_day := daylight_share[season(tick)] / 2.0
	var from_noon := absf(day_phase(tick) - NOON)
	if twilight <= 0.0:
		return 1.0 if from_noon <= half_day else night_light
	var t := clampf((half_day + twilight / 2.0 - from_noon) / twilight, 0.0, 1.0)
	return lerpf(night_light, 1.0, t)


func season_name(tick: int) -> String:
	return SEASON_NAMES[season(tick)]


func describe(tick: int) -> String:
	return "Year %d, %s day %d, %02d:%02d" % [year(tick) + 1, season_name(tick).capitalize(),
			day_of_season(tick) + 1, hour(tick), minute(tick)]
