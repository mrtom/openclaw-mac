[[Task inbox]]

> [!warning] Due Today
> ```tasks
> not done
> due today
> sort by priority
> hide toolbar
> ```

> [!info] Upcoming (Next 7 Days)
> ```tasks
> not done
> due before in 7 days
> sort by due
> hide toolbar
> ```

## Faculty

> [!work] Active Work Tasks
> ```tasks
> not done
> tag includes #work
> sort by due
> hide toolbar
> ```

> [!work]- Recently Completed Work
> ```tasks
> done
> tag includes #work
> done after 7 days ago
> sort by done reverse
> hide toolbar
> ```

### Waiting on others
```tasks
not done
tag includes #work
(description includes [[)
group by function task.description.match(/\[\[([^\]]+)\]\]/)?.[0] || "Unassigned"
sort by due
hide toolbar
```

## Personal

> [!personal] Active Personal Tasks
> ```tasks
> not done
> tag includes #personal
> sort by due
> hide toolbar
> ```

> [!personal]- Recently Completed Personal
> ```tasks
> done
> tag includes #personal
> done after 7 days ago
> sort by done reverse
> hide toolbar
> ```
