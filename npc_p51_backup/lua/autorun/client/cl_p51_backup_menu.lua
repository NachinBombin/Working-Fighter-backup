if not CLIENT then return end

-- ============================================================
-- CONSOLE COMMAND — manual test spawn
-- ============================================================

concommand.Add("p51backup_spawn", function()
    if not IsValid(LocalPlayer()) then return end
    net.Start("P51Backup_ManualSpawn")
    net.SendToServer()
end)

-- ============================================================
-- CONTROL PANEL
-- ============================================================

hook.Add("AddToolMenuTabs", "P51Backup_Tab", function()
    spawnmenu.AddToolTab("Bombin Support", "Bombin Support", "icon16/bomb.png")
end)

hook.Add("AddToolMenuCategories", "P51Backup_Categories", function()
    spawnmenu.AddToolCategory("Bombin Support", "Backup Fighter Plane", "Backup Fighter Plane")
end)

hook.Add("PopulateToolMenu", "P51Backup_ToolMenu", function()
    spawnmenu.AddToolMenuOption("Bombin Support", "Backup Fighter Plane", "p51backup_settings", "P-51D V2 Settings", "", "", function(panel)
        panel:ClearControls()
        panel:Help("NPC Call Settings")

        panel:CheckBox("Enable NPC calls",          "npc_p51backup_enabled")

        panel:NumSlider("Call chance (per check)",   "npc_p51backup_chance",    0,   1,    2)
        panel:NumSlider("Check interval (seconds)",  "npc_p51backup_interval",  1,   60,   0)
        panel:NumSlider("NPC cooldown (seconds)",    "npc_p51backup_cooldown",  10,  300,  0)
        panel:NumSlider("Min call distance (HU)",    "npc_p51backup_min_dist",  100, 1000, 0)
        panel:NumSlider("Max call distance (HU)",    "npc_p51backup_max_dist",  500, 8000, 0)
        panel:NumSlider("Flare → arrival delay (s)", "npc_p51backup_delay",     1,   30,   0)

        panel:Help("Spawn Behaviour")
        panel:NumSlider("Spawn altitude above ground (HU)", "npc_p51backup_height", 500, 8000, 0)

        panel:Help("Debug")
        panel:CheckBox("Enable debug prints", "npc_p51backup_announce")

        panel:Help("Manual spawn (for testing)")
        panel:Button("Spawn P-51D V2 now", "p51backup_spawn")
    end)
end)
