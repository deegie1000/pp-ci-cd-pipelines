
using Microsoft.Crm.Sdk.Messages;
using Microsoft.PowerPlatform.Dataverse.Client;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Messages;
using Microsoft.Xrm.Sdk.Metadata;
using Microsoft.Xrm.Sdk.Query;
using System;
using System.Collections.Generic;
using System.Linq;

class Program
{
    // Run:
    // dotnet run -- \
    //   --url https://<yourorg>.crm.dynamics.com \
    //   --targetUniquename <your-target-solution-unique-name> \
    //   [--websiteName "<friendly name of your Power Pages site>"] \
    //   --useDefaultDiff true
    //
    // If --websiteName is omitted, ALL Power Pages sites are processed.

    static int Main(string[] args)
    {
        string url = GetArg(args, "--url") ?? "https://<yourorg>.crm.dynamics.com";
        string targetSolutionUniqueName = GetArg(args, "--targetUniquename") ?? "<target-solution>";
        string websiteFriendlyName = GetArg(args, "--websiteName"); // optional
        bool useDefaultDiff = GetArgFlag(args, "--useDefaultDiff");

        // Interactive OAuth per Microsoft quickstart (keep AppId unchanged).
        var connectionString =
            $@"AuthType=OAuth;
               Url={url};
               AppId=51f81489-12ee-4a9e-aaae-a2591f45987d;
               RedirectUri=http://localhost;
               LoginPrompt=Auto;
               RequireNewInstance=True";

        using var svc = new ServiceClient(connectionString);
        if (!svc.IsReady)
        {
            Console.Error.WriteLine($"Dataverse connection failed: {svc.LastError}");
            return 2;
        }

        try
        {
            // 1) Resolve target solution
            var targetSolution = ResolveSolutionByUniqueName(svc, targetSolutionUniqueName);
            if (targetSolution == null)
            {
                Console.Error.WriteLine($"Target solution '{targetSolutionUniqueName}' not found.");
                return 3;
            }
            Console.WriteLine($"Target solution: {targetSolution.GetAttributeValue<string>("friendlyname")} [{targetSolutionUniqueName}]");
            var targetSolutionId = targetSolution.Id;

            // 2) Resolve Power Pages component type integers via SDK
            int siteType = ResolveComponentType(svc, "powerpagesite");
            int siteComponentType = ResolveComponentType(svc, "powerpagecomponent");
            int siteLanguageType = ResolveComponentType(svc, "powerpagesitelanguage");
            if (siteType <= 0 || siteComponentType <= 0 || siteLanguageType <= 0)
            {
                Console.Error.WriteLine("Could not resolve component types for powerpagesite/powerpagecomponent/powerpagesitelanguage.");
                return 4;
            }
            Console.WriteLine($"Resolved types: site={siteType}, component={siteComponentType}, language={siteLanguageType}");

            // 3) Load sites: one site by name if provided; else all sites in environment
            List<Entity> sites = new();
            if (!string.IsNullOrWhiteSpace(websiteFriendlyName))
            {
                var single = FindPowerPagesSiteByName(svc, websiteFriendlyName);
                if (single == null)
                {
                    Console.Error.WriteLine($"Power Pages site '{websiteFriendlyName}' not found.");
                    return 5;
                }
                sites.Add(single);
            }
            else
            {
                sites = GetAllSites(svc);
                if (sites.Count == 0)
                {
                    Console.WriteLine("No Power Pages sites found in the environment.");
                    return 0;
                }
                Console.WriteLine($"Found {sites.Count} site(s) to process.");
            }

            // 4) Process each site: add site + missing site components (no required deps)
            int totalAdded = 0, totalSkipped = 0, totalFailed = 0;
            foreach (var site in sites)
            {
                var name = site.GetAttributeValue<string>("name") ?? "(unnamed)";
                var id = site.Id;
                Console.WriteLine($"\n=== Processing site: {name} ({id}) ===");

                var (added, skipped, failed) =
                    ProcessSite(svc, targetSolutionId, targetSolutionUniqueName,
                                siteType, siteComponentType, useDefaultDiff, site);

                totalAdded += added;
                totalSkipped += skipped;
                totalFailed += failed;
            }

            Console.WriteLine($"\nAdd phase summary (all sites): Added={totalAdded}, Skipped={totalSkipped}, Failed={totalFailed}");

            // 5) FINAL CLEAN-UP: REMOVE ONLY TABLES (Entities) from target solution
            var removedTables = RemoveTablesFromSolution(svc, targetSolutionId, targetSolutionUniqueName);
            Console.WriteLine($"Cleanup complete. Removed {removedTables} table(s) from solution.");

            return totalFailed == 0 ? 0 : 6;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(e);
            return 99;
        }
    }

    // --- Site processing -----------------------------------------------------

    static (int Added, int Skipped, int Failed) ProcessSite(
        ServiceClient svc,
        Guid targetSolutionId,
        string targetSolutionUniqueName,
        int siteType,
        int siteComponentType,
        bool useDefaultDiff,
        Entity site)
    {
        int added = 0, skipped = 0, failed = 0;

        var siteName = site.GetAttributeValue<string>("name") ?? "(unnamed)";
        var siteId = site.Id;

        // A) Add the Site (idempotent)
        var siteCheck = EnsureComponentInSolution(
            svc,
            targetSolutionId,
            targetSolutionUniqueName,
            siteType,
            siteId);

        if (siteCheck.Added)
            Console.WriteLine($"✔ Added site to solution: {siteName} ({siteId})");
        else
            Console.WriteLine($"↷ Site {siteName} ({siteId}) {siteCheck.Note}");

        // B) Build source set of site components and target membership
        var allSiteComponents = GetAllSiteComponents(svc, siteId);
        var sourceSet = new HashSet<Guid>(allSiteComponents.Select(e => e.Id));

        if (useDefaultDiff)
        {
            var defaultSolution = ResolveDefaultSolution(svc);
            if (defaultSolution == null)
            {
                Console.WriteLine("WARN: Default solution not found; falling back to all site components as source.");
            }
            else
            {
                var defaultIds = GetSolutionMembership(svc, defaultSolution.Id, siteComponentType);
                sourceSet.IntersectWith(defaultIds);
                Console.WriteLine($"Source set (Default ∩ site components) count: {sourceSet.Count}");
            }
        }
        else
        {
            Console.WriteLine($"Source set (all site components) count: {sourceSet.Count}");
        }

        var targetMembership = new HashSet<Guid>(GetSolutionMembership(svc, targetSolutionId, siteComponentType));
        var toAddIds = sourceSet.Except(targetMembership).ToHashSet();
        Console.WriteLine($"Diff: {toAddIds.Count} site component(s) not yet in target.");

        // Lookup names for logging
        var idToName = allSiteComponents.ToDictionary(
            e => e.Id,
            e => e.GetAttributeValue<string>("name") ?? "(unnamed component)");

        // C) Add missing site components (pre-check)
        foreach (var compId in toAddIds)
        {
            string compName = idToName.TryGetValue(compId, out var nm) ? nm : "(unknown)";
            var res = EnsureComponentInSolution(
                svc,
                targetSolutionId,
                targetSolutionUniqueName,
                siteComponentType,
                compId);

            if (res.Added)
            {
                added++;
                Console.WriteLine($"✔ Added site component: {compName} ({compId})");
            }
            else if (res.Note.StartsWith("add failed", StringComparison.OrdinalIgnoreCase))
            {
                failed++;
                Console.WriteLine($"✖ Failed to add {compName} ({compId}): {res.Note}");
            }
            else
            {
                skipped++;
                Console.WriteLine($"↷ Skipped {compName} ({compId}) — {res.Note}");
            }
        }

        Console.WriteLine($"Site summary [{siteName}]: Added={added}, Skipped={skipped}, Failed={failed}");
        return (added, skipped, failed);
    }

    // --- Query helpers -------------------------------------------------------

    static List<Entity> GetAllSites(ServiceClient svc)
    {
        var q = new QueryExpression("powerpagesite")
        {
            ColumnSet = new ColumnSet("powerpagesiteid", "name")
        };
        return svc.RetrieveMultiple(q).Entities.ToList();
    }

    static Entity ResolveSolutionByUniqueName(ServiceClient svc, string uniqueName)
    {
        var q = new QueryExpression("solution")
        {
            ColumnSet = new ColumnSet("solutionid", "friendlyname", "uniquename")
        };
        q.Criteria.AddCondition("uniquename", ConditionOperator.Equal, uniqueName);
        return svc.RetrieveMultiple(q).Entities.FirstOrDefault();
    }

    static Entity FindPowerPagesSiteByName(ServiceClient svc, string friendlyName)
    {
        var q = new QueryExpression("powerpagesite")
        {
            ColumnSet = new ColumnSet("powerpagesiteid", "name")
        };
        q.Criteria.AddCondition("name", ConditionOperator.Equal, friendlyName);
        return svc.RetrieveMultiple(q).Entities.FirstOrDefault();
    }

    /// <summary>
    /// Resolve solution component type integers via SDK (solutioncomponentdefinition).
    /// </summary>
    static int ResolveComponentType(ServiceClient svc, string name)
    {
        var q = new QueryExpression("solutioncomponentdefinition")
        {
            ColumnSet = new ColumnSet("name", "solutioncomponenttype")
        };
        q.Criteria.AddCondition("name", ConditionOperator.Equal, name);

        var row = svc.RetrieveMultiple(q).Entities.FirstOrDefault();
        return row?.GetAttributeValue<int?>("solutioncomponenttype") ?? -1;
    }

    /// <summary>
    /// Get all powerpagecomponent rows for a given site.
    /// </summary>
    static List<Entity> GetAllSiteComponents(ServiceClient svc, Guid siteId)
    {
        var compQuery = new QueryExpression("powerpagecomponent")
        {
            ColumnSet = new ColumnSet("powerpagecomponentid", "name", "powerpagesiteid")
        };
        compQuery.Criteria.AddCondition("powerpagesiteid", ConditionOperator.Equal, siteId);
        return svc.RetrieveMultiple(compQuery).Entities.ToList();
    }

    /// <summary>
    /// Returns the objectIds already present in solutioncomponent for a given solution + componentType.
    /// </summary>
    static IEnumerable<Guid> GetSolutionMembership(ServiceClient svc, Guid solutionId, int componentType)
    {
        var q = new QueryExpression("solutioncomponent")
        {
            ColumnSet = new ColumnSet("objectid"),
        };

        Console.WriteLine("Solution ID: " + solutionId.ToString() + ", Component Type: " + componentType.ToString());
        q.Criteria.AddCondition("solutionid", ConditionOperator.Equal, solutionId);
        q.Criteria.AddCondition("componenttype", ConditionOperator.Equal, componentType);

        var results = svc.RetrieveMultiple(q).Entities;
        foreach (var e in results)
        {
            var id = e.GetAttributeValue<Guid?>("objectid");
            if (id.HasValue) yield return id.Value;
        }
    }

    /// <summary>
    /// Count rows present in solutioncomponent for (solution, type, objectid).
    /// </summary>
    static int CountMembership(ServiceClient svc, Guid solutionId, int componentType, Guid objectId)
    {
        var q = new QueryExpression("solutioncomponent")
        {
            ColumnSet = new ColumnSet("solutioncomponentid"),
        };
        q.Criteria.AddCondition("solutionid", ConditionOperator.Equal, solutionId);
        q.Criteria.AddCondition("componenttype", ConditionOperator.Equal, componentType);
        q.Criteria.AddCondition("objectid", ConditionOperator.Equal, objectId);

        return svc.RetrieveMultiple(q).Entities.Count;
    }

    /// <summary>
    /// Ensures the component is in the solution: pre-check then add (idempotent).
    /// Returns (Added, Note).
    /// </summary>
    static (bool Added, string Note) EnsureComponentInSolution(
        ServiceClient svc,
        Guid solutionId,
        string solutionUniqueName,
        int componentType,
        Guid objectId)
    {
        var existing = CountMembership(svc, solutionId, componentType, objectId);
        if (existing > 0)
        {
            return (false, existing == 1
                ? "already present (1 row)"
                : $"already present ({existing} rows) – duplicates exist");
        }

        var add = new AddSolutionComponentRequest
        {
            ComponentId = objectId,
            ComponentType = componentType,
            SolutionUniqueName = solutionUniqueName,
            // Per your requirement, DO NOT include additional required components
            AddRequiredComponents = false
        };

        try
        {
            svc.Execute(add); // AddSolutionComponent
            return (true, "added");
        }
        catch (Exception ex)
        {
            return (false, $"add failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Resolve the Default solution (Common Data Services Default Solution / Default Solution).
    /// </summary>
    static Entity? ResolveDefaultSolution(ServiceClient svc)
    {
        var byUnique = ResolveSolutionByUniqueName(svc, "Default");
        if (byUnique != null) return byUnique;

        var friendlyCandidates = new[]
        {
            "Common Data Services Default Solution",
            "Default Solution"
        };

        foreach (var f in friendlyCandidates)
        {
            var q = new QueryExpression("solution")
            {
                ColumnSet = new ColumnSet("solutionid", "friendlyname", "uniquename")
            };
            q.Criteria.AddCondition("friendlyname", ConditionOperator.Equal, f);
            var row = svc.RetrieveMultiple(q).Entities.FirstOrDefault();
            if (row != null) return row;
        }

        return null;
    }

    /// <summary>
    /// Final clean-up: remove all Table components (Entity = 1) from the target solution.
    /// This does NOT delete the tables from Dataverse; it only removes their membership in the solution.
    /// </summary>
    static int RemoveTablesFromSolution(ServiceClient svc, Guid targetSolutionId, string targetSolutionUniqueName)
    {
        const int ENTITY_COMPONENT_TYPE = 1; // Entity/Table

        // Get all table component IDs (objectid is the Entity MetadataId)
        var tableIds = GetSolutionMembership(svc, targetSolutionId, ENTITY_COMPONENT_TYPE).ToList();
        if (tableIds.Count == 0)
        {
            Console.WriteLine("No tables found in target solution to remove.");
            return 0;
        }

        int removed = 0, failed = 0;
        foreach (var metadataId in tableIds)
        {
            string logicalName = ResolveTableLogicalName(svc, metadataId);

            try
            {
                var removeReq = new RemoveSolutionComponentRequest
                {
                    ComponentId = metadataId,
                    ComponentType = ENTITY_COMPONENT_TYPE,
                    SolutionUniqueName = targetSolutionUniqueName
                };
                svc.Execute(removeReq);

                removed++;
                Console.WriteLine($"🗑️ Removed table from solution: {logicalName} ({metadataId})");
            }
            catch (Exception ex)
            {
                failed++;
                Console.WriteLine($"⚠️ Failed to remove table {logicalName} ({metadataId}): {ex.Message}");
            }
        }

        if (failed > 0)
            Console.WriteLine($"Cleanup summary: Removed={removed}, Failed={failed}");

        return removed;
    }

    /// <summary>
    /// Resolve a table's logical name via RetrieveEntityRequest using the MetadataId.
    /// </summary>
    static string ResolveTableLogicalName(ServiceClient svc, Guid metadataId)
    {
        try
        {
            var req = new RetrieveEntityRequest
            {
                MetadataId = metadataId,
                EntityFilters = EntityFilters.Entity
            };
            var resp = (RetrieveEntityResponse)svc.Execute(req);
            return resp?.EntityMetadata?.LogicalName ?? "(unknown logical name)";
        }
        catch
        {
            return "(unknown logical name)";
        }
    }

    // --- Args parsing --------------------------------------------------------

    /// <summary>
    /// Reads a boolean flag from args.
    /// Supports:
    ///   --flag                => true
    ///   --flag true|false     => explicit
    ///   --flag=true|false     => explicit
    /// Also accepts 1/0, yes/no, on/off, y/n.
    /// Returns false if the flag isn't provided.
    /// </summary>
    static bool GetArgFlag(string[] args, string key)
    {
        if (args == null || args.Length == 0 || string.IsNullOrWhiteSpace(key))
            return false;

        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];

            // Case: --flag=value
            if (a.StartsWith(key + "=", StringComparison.OrdinalIgnoreCase))
            {
                var value = a.Substring(key.Length + 1);
                if (TryParseBool(value, out bool explicitVal))
                    return explicitVal;
                // Malformed value => treat presence as true
                return true;
            }

            // Case: exact match "--flag"
            if (a.Equals(key, StringComparison.OrdinalIgnoreCase))
            {
                // If no value follows or next token is another key, treat as true
                if (i + 1 >= args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
                    return true;

                // Next token provided — try parse it as bool-like string
                if (TryParseBool(args[i + 1], out bool explicitVal))
                    return explicitVal;

                // Malformed value — presence implies true
                return true;
            }
        }

        // Not present
        return false;
    }

    /// <summary>
    /// Tries to parse common boolean representations.
    /// Returns true if parsed; result set accordingly.
    /// </summary>
    static bool TryParseBool(string? value, out bool result)
    {
        result = false;
        if (string.IsNullOrWhiteSpace(value)) return false;

        // Native true/false first
        if (bool.TryParse(value, out result)) return true;

        switch (value.Trim().ToLowerInvariant())
        {
            case "1":
            case "y":
            case "yes":
            case "on":
                result = true; return true;

            case "0":
            case "n":
            case "no":
            case "off":
                result = false; return true;
        }

        return false;
    }

    /// <summary>
    /// Reads a string argument from args with a single return.
    /// Supports:
    ///   --key value
    ///   --key=value
    /// Returns null if the key isn't provided or no value is found.
    /// </summary>
    static string? GetArg(string[] args, string key)
    {
        string? result = null;

        if (args != null && args.Length > 0 && !string.IsNullOrWhiteSpace(key))
        {
            for (int i = 0; i < args.Length; i++)
            {
                var a = args[i];

                // Case: --key=value
                if (a.StartsWith(key + "=", StringComparison.OrdinalIgnoreCase))
                {
                    result = a.Substring(key.Length + 1);
                    break;
                }

                // Case: exact match "--key"
                if (a.Equals(key, StringComparison.OrdinalIgnoreCase))
                {
                    if (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
                        result = args[i + 1];
                    // else leave result=null
                    break;
                }
            }
        }

        return result;
    }
}