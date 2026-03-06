type PlanStep = {
    step?: string | null
    status?: 'pending' | 'in_progress' | 'completed' | null
}

type PlanUpdate = {
    explanation?: string | null
    plan?: PlanStep[] | null
}

export function PlanUpdatePanel(props: { planUpdate: PlanUpdate | null | undefined }) {
    const planUpdate = props.planUpdate
    if (!planUpdate) return null

    const explanation = typeof planUpdate.explanation === 'string' ? planUpdate.explanation.trim() : ''
    const steps = Array.isArray(planUpdate.plan) ? planUpdate.plan : []

    return (
        <div className="px-3 pt-3">
            <div className="mx-auto w-full max-w-content rounded-md border border-[var(--app-divider)] bg-[var(--app-subtle-bg)] p-3">
                <div className="text-xs font-semibold text-[var(--app-hint)]">Plan</div>
                {explanation ? (
                    <div className="mt-1 text-sm text-[var(--app-text)]">{explanation}</div>
                ) : null}
                <div className="mt-2 space-y-1 text-sm">
                    {steps.length === 0 ? (
                        <div className="text-[var(--app-hint)]">No steps yet.</div>
                    ) : (
                        steps.map((item, idx) => {
                            const status = item.status
                            const icon =
                                status === 'completed' ? '✓' : status === 'in_progress' ? '›' : '•'
                            const stepText = typeof item.step === 'string' ? item.step : ''
                            const stepClass =
                                status === 'completed'
                                    ? 'text-[var(--app-hint)] line-through'
                                    : 'text-[var(--app-text)]'
                            return (
                                <div key={`${idx}-${stepText}`} className="flex gap-2">
                                    <div className="w-4 shrink-0 text-[var(--app-hint)]">{icon}</div>
                                    <div className={stepClass}>{stepText}</div>
                                </div>
                            )
                        })
                    )}
                </div>
            </div>
        </div>
    )
}

