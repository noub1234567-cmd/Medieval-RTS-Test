extends Resource
class_name SoldierData

@export var unit_id: String = ""
@export var display_name: String = ""
@export var description: String = ""
@export var max_health: int = 100
@export var attack_damage: int = 15
@export var building_damage: int = 15
@export var attack_range: float = 42.0
@export var detection_range: float = 220.0
@export var attack_cooldown: float = 1.0
@export var movement_speed: float = 120.0
@export var armor: int = 0
@export var food_cost: int = 50
@export var gold_cost: int = 25
@export var population_cost: int = 1
@export var attack_type: String = "melee"
@export var unit_class: String = "infantry"
