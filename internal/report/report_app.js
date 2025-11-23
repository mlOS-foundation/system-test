// MLOS E2E Test Report - React Application
// This file is loaded separately to avoid Go template parsing conflicts with JSX

const { useState, useEffect, useRef } = React;

// Collapsible Metric Folder Component
function MetricFolder({ title, icon, children, defaultExpanded = false }) {
    const [expanded, setExpanded] = useState(defaultExpanded);
    
    const headerClass = 'metric-folder-header ' + (expanded ? 'expanded' : '');
    const contentClass = 'metric-folder-content ' + (expanded ? 'expanded' : '');
    return (
        React.createElement('div', { className: 'metric-folder' },
            React.createElement('div', {
                className: headerClass,
                onClick: () => setExpanded(!expanded)
            },
                React.createElement('h3', null, icon, ' ', title),
                React.createElement('span', { className: 'icon' }, '▶')
            ),
            React.createElement('div', { className: contentClass },
                React.createElement('div', { className: 'metric-folder-body' },
                    children
                )
            )
        )
    );
}

// Chart Component
function ChartComponent({ type, data, options, height = 400 }) {
    const canvasRef = useRef(null);
    const chartRef = useRef(null);
    const heightPx = height + 'px';
    const dataRef = useRef(data);
    const optionsRef = useRef(options);
    const [chartError, setChartError] = useState(null);
    
    // Update refs when props change
    useEffect(() => {
        dataRef.current = data;
        optionsRef.current = options;
    }, [data, options]);
    
    useEffect(() => {
        let mounted = true;
        let retryCount = 0;
        const maxRetries = 50; // 5 seconds max
        
        function initChart() {
            if (!mounted) return;
            
            if (typeof Chart === 'undefined') {
                if (retryCount < maxRetries) {
                    retryCount++;
                    setTimeout(initChart, 100);
                    return;
                } else {
                    console.error('Chart.js failed to load after 5 seconds');
                    setChartError('Chart.js library not loaded. Please check your internet connection.');
                    return;
                }
            }
            
            if (!canvasRef.current) {
                // Canvas not mounted yet, retry
                if (retryCount < maxRetries) {
                    retryCount++;
                    setTimeout(initChart, 100);
                    return;
                }
                return;
            }
            
            try {
                const ctx = canvasRef.current.getContext('2d');
                if (!ctx) {
                    console.error('Could not get 2d context from canvas');
                    setChartError('Could not initialize canvas');
                    return;
                }
                
                if (chartRef.current) {
                    chartRef.current.destroy();
                }
                
                chartRef.current = new Chart(ctx, {
                    type: type,
                    data: dataRef.current,
                    options: {
                        ...optionsRef.current,
                        responsive: true,
                        maintainAspectRatio: false,
                    }
                });
                
                console.log('Chart initialized successfully:', type, dataRef.current);
                setChartError(null);
            } catch (error) {
                console.error('Error initializing chart:', error, error.stack);
                setChartError('Error rendering chart: ' + error.message);
            }
        }
        
        // Start initialization
        initChart();
        
        return () => {
            mounted = false;
            if (chartRef.current) {
                chartRef.current.destroy();
                chartRef.current = null;
            }
        };
    }, [type]); // Only re-run when chart type changes
    
    const styleObj = {height: heightPx};
    
    // Show fallback if Chart.js fails or error occurs
    if (chartError || typeof Chart === 'undefined') {
        // Create a visual fallback showing the data
        const chartData = dataRef.current;
        let fallbackContent = [];
        
        if (chartData && chartData.labels && chartData.datasets && chartData.datasets[0]) {
            const labels = chartData.labels;
            const values = chartData.datasets[0].data;
            const colors = chartData.datasets[0].backgroundColor || [];
            
            fallbackContent = labels.map((label, idx) => {
                const value = values[idx] || 0;
                const color = colors[idx] || 'rgba(102, 126, 234, 0.8)';
                const bgColor = color.replace('0.8', '0.2');
                
                return React.createElement('div', {
                    key: idx,
                    style: {
                        marginBottom: '15px',
                        padding: '15px',
                        background: bgColor,
                        borderRadius: '8px',
                        borderLeft: '4px solid ' + color
                    }
                },
                    React.createElement('div', { style: { fontWeight: 'bold', marginBottom: '5px' } }, label),
                    React.createElement('div', { style: { fontSize: '1.5em', color: color } }, value + (type === 'doughnut' ? '' : ' ms'))
                );
            });
        }
        
        return React.createElement('div', { className: 'chart-container', style: styleObj },
            React.createElement('div', { style: { padding: '20px' } },
                chartError ? React.createElement('p', { style: { color: '#ef4444', marginBottom: '15px' } }, '⚠️ ' + chartError) : null,
                typeof Chart === 'undefined' ? React.createElement('p', { style: { color: '#f59e0b', marginBottom: '15px' } }, '⚠️ Chart.js not loaded. Showing data as list.') : null,
                React.createElement('div', null, fallbackContent)
            )
        );
    }
    
    return React.createElement('div', { className: 'chart-container', style: styleObj },
        React.createElement('canvas', { ref: canvasRef })
    );
}

// Main App Component
function App() {
    // Get report data from global variable set by Go template
    const reportData = window.reportData;
    
    // Ensure we have valid data
    const axonTime = Math.max(reportData.axonDownloadTime || 0, 1);
    const coreDownloadTime = Math.max(reportData.coreDownloadTime || 0, 1);
    const coreStartupTime = Math.max(reportData.coreStartupTime || 0, 1);
    
    const installationChartData = {
        labels: ['Axon Download', 'Core Download', 'Core Startup'],
        datasets: [{
            label: 'Time (ms)',
            data: [axonTime, coreDownloadTime, coreStartupTime],
            backgroundColor: [
                'rgba(102, 126, 234, 0.8)',
                'rgba(118, 75, 162, 0.8)',
                'rgba(17, 153, 142, 0.8)'
            ],
            borderColor: [
                'rgb(102, 126, 234)',
                'rgb(118, 75, 162)',
                'rgb(17, 153, 142)'
            ],
            borderWidth: 2
        }]
    };
    
    console.log('Installation chart data:', installationChartData);
    
    // inferenceLabels, inferenceData, and inferenceColors are already JSON arrays from Go template
    // They're inserted as template.JS which is already valid JavaScript, so we can use them directly
    let inferenceLabels = [];
    let inferenceData = [];
    let inferenceColors = [];
    
    try {
        if (Array.isArray(reportData.inferenceLabels)) {
            inferenceLabels = reportData.inferenceLabels;
        } else if (typeof reportData.inferenceLabels === 'string') {
            inferenceLabels = JSON.parse(reportData.inferenceLabels);
        }
        
        if (Array.isArray(reportData.inferenceData)) {
            inferenceData = reportData.inferenceData;
        } else if (typeof reportData.inferenceData === 'string') {
            inferenceData = JSON.parse(reportData.inferenceData);
        }
        
        if (Array.isArray(reportData.inferenceColors)) {
            inferenceColors = reportData.inferenceColors;
        } else if (typeof reportData.inferenceColors === 'string') {
            inferenceColors = JSON.parse(reportData.inferenceColors);
        }
    } catch (e) {
        console.error('Error parsing inference data:', e);
    }
    
    const inferenceChartData = {
        labels: inferenceLabels.length > 0 ? inferenceLabels : ['No data'],
        datasets: [{
            label: 'Inference Time (ms)',
            data: inferenceData.length > 0 ? inferenceData : [0],
            backgroundColor: inferenceColors.length > 0 ? inferenceColors : ['rgba(102, 126, 234, 0.8)'],
            borderColor: inferenceColors.length > 0 ? inferenceColors.map(c => (typeof c === 'string' ? c.replace('0.8', '1') : c)) : ['rgb(102, 126, 234)'],
            borderWidth: 2
        }]
    };
    
    console.log('Inference chart data:', inferenceChartData);
    
    const totalRegisterTime = Math.max(reportData.totalRegisterTime || 0, 1);
    const totalInferenceTime = Math.max(reportData.totalInferenceTime || 0, 1);
    
    const breakdownChartData = {
        labels: ['Axon Download', 'Core Download', 'Model Registration', 'Inference Tests'],
        datasets: [{
            data: [axonTime, coreDownloadTime, totalRegisterTime, totalInferenceTime],
            backgroundColor: [
                'rgba(102, 126, 234, 0.8)',
                'rgba(118, 75, 162, 0.8)',
                'rgba(56, 239, 125, 0.8)',
                'rgba(240, 147, 251, 0.8)'
            ],
            borderWidth: 2
        }]
    };
    
    console.log('Breakdown chart data:', breakdownChartData);
    
    const cardClass = 'summary-card ' + (reportData.successRate === 100 ? 'success' : 'warning');
    
    return React.createElement('div', { className: 'container' },
        React.createElement('div', { className: 'header' },
            React.createElement('h1', null, '🧠 MLOS Release E2E Validation Report'),
            React.createElement('p', null, 'Signal. Propagate. Myelinate.'),
            React.createElement('p', { style: { fontSize: '0.9em', marginTop: '10px', opacity: 0.8 } },
                'Generated: ', reportData.timestamp
            )
        ),
        React.createElement('div', { className: 'summary' },
            React.createElement('div', { className: cardClass },
                React.createElement('h3', null, 'Success Rate'),
                React.createElement('div', { className: 'value' }, reportData.successRate.toFixed(1) + '%')
            ),
            React.createElement('div', { className: 'summary-card' },
                React.createElement('h3', null, 'Total Duration'),
                React.createElement('div', { className: 'value' }, reportData.totalDuration.toFixed(2) + 's')
            ),
            React.createElement('div', { className: 'summary-card' },
                React.createElement('h3', null, 'Inferences'),
                React.createElement('div', { className: 'value' }, reportData.successfulInferences + '/' + reportData.totalInferences)
            ),
            React.createElement('div', { className: 'summary-card' },
                React.createElement('h3', null, 'Models Installed'),
                React.createElement('div', { className: 'value' }, reportData.modelsInstalled)
            ),
            React.createElement('div', { className: 'summary-card' },
                React.createElement('h3', null, 'Axon Version'),
                React.createElement('div', { className: 'value', style: { fontSize: '1.2em' } }, reportData.axonVersion)
            ),
            React.createElement('div', { className: 'summary-card' },
                React.createElement('h3', null, 'Core Version'),
                React.createElement('div', { className: 'value', style: { fontSize: '1.2em' } }, reportData.coreVersion)
            )
        ),
        React.createElement('div', { className: 'section' },
            React.createElement('h2', null, '📊 Installation & Setup Times'),
            React.createElement(MetricFolder, { title: 'Installation Metrics', icon: '⏱️', defaultExpanded: true },
                React.createElement(ChartComponent, {
                    type: 'bar',
                    data: installationChartData,
                    options: {
                        plugins: {
                            legend: { display: false },
                            title: {
                                display: true,
                                text: 'Installation & Setup Times',
                                font: { size: 16, weight: 'bold' }
                            }
                        },
                        scales: {
                            y: {
                                beginAtZero: true,
                                title: { display: true, text: 'Time (milliseconds)' }
                            }
                        }
                    },
                    height: 400
                }),
                React.createElement('div', { className: 'metric-grid', style: { marginTop: '20px' } },
                    React.createElement('div', { className: 'metric-item' },
                        React.createElement('div', { className: 'metric-item-label' }, 'Axon Download'),
                        React.createElement('div', { className: 'metric-item-value' }, reportData.axonDownloadTime + ' ms')
                    ),
                    React.createElement('div', { className: 'metric-item' },
                        React.createElement('div', { className: 'metric-item-label' }, 'Core Download'),
                        React.createElement('div', { className: 'metric-item-value' }, reportData.coreDownloadTime + ' ms')
                    ),
                    React.createElement('div', { className: 'metric-item' },
                        React.createElement('div', { className: 'metric-item-label' }, 'Core Startup'),
                        React.createElement('div', { className: 'metric-item-value' }, reportData.coreStartupTime + ' ms')
                    )
                )
            )
        ),
        React.createElement('div', { className: 'section' },
            React.createElement('h2', null, '📝 Model Registration'),
            reportData.registrationMetrics && reportData.registrationMetrics.length > 0 ? (
                React.createElement(MetricFolder, {
                    title: 'Registered Models (' + reportData.registrationMetrics.length + ')',
                    icon: '✅'
                },
                    React.createElement('div', { className: 'metric-grid' },
                        reportData.registrationMetrics.map((metric, idx) =>
                            React.createElement('div', { key: idx, className: 'metric-item ' + metric.status },
                                React.createElement('div', { className: 'metric-item-label' }, metric.name + ' Registration'),
                                React.createElement('div', { className: 'metric-item-value' }, metric.value + ' ms'),
                                React.createElement('div', { className: 'metric-item-status' },
                                    React.createElement('span', { className: 'badge ' + metric.status }, metric.statusText)
                                )
                            )
                        )
                    )
                )
            ) : (
                React.createElement('p', { style: { color: '#666', fontStyle: 'italic' } }, 'No registration metrics available')
            )
        ),
        React.createElement('div', { className: 'section' },
            React.createElement('h2', null, '🧪 Inference Performance'),
            reportData.inferenceMetrics && reportData.inferenceMetrics.length > 0 ? (
                React.createElement(React.Fragment, null,
                    React.createElement(MetricFolder, { title: 'Inference Chart', icon: '📈', defaultExpanded: true },
                        React.createElement(ChartComponent, {
                            type: 'bar',
                            data: inferenceChartData,
                            options: {
                                plugins: {
                                    legend: { display: false },
                                    title: {
                                        display: true,
                                        text: 'Inference Performance by Model',
                                        font: { size: 16, weight: 'bold' }
                                    }
                                },
                                scales: {
                                    y: {
                                        beginAtZero: true,
                                        title: { display: true, text: 'Time (milliseconds)' }
                                    }
                                }
                            },
                            height: 400
                        })
                    ),
                    React.createElement(MetricFolder, {
                        title: 'Individual Model Metrics (' + reportData.inferenceMetrics.length + ')',
                        icon: '📋'
                    },
                        React.createElement('div', { className: 'metric-grid' },
                            reportData.inferenceMetrics.map((metric, idx) =>
                                React.createElement('div', { key: idx, className: 'metric-item ' + metric.status },
                                    React.createElement('div', { className: 'metric-item-label' },
                                        metric.name + ' (' + (metric.type === 'inference-small' ? 'Small' : 'Large') + ')'
                                    ),
                                    React.createElement('div', { className: 'metric-item-value' }, metric.value + ' ms'),
                                    React.createElement('div', { className: 'metric-item-status' },
                                        React.createElement('span', { className: 'badge ' + metric.status }, metric.statusText)
                                    )
                                )
                            )
                        )
                    )
                )
            ) : (
                React.createElement('p', { style: { color: '#666', fontStyle: 'italic' } }, 'No inference metrics available')
            )
        ),
        React.createElement('div', { className: 'section' },
            React.createElement('h2', null, '⏱️ Performance Breakdown'),
            React.createElement(MetricFolder, { title: 'Time Distribution', icon: '🥧', defaultExpanded: true },
                React.createElement(ChartComponent, {
                    type: 'doughnut',
                    data: breakdownChartData,
                    options: {
                        plugins: {
                            legend: { position: 'right' },
                            title: {
                                display: true,
                                text: 'Time Distribution Across Test Phases',
                                font: { size: 16, weight: 'bold' }
                            }
                        }
                    },
                    height: 400
                })
            )
        ),
        reportData.hardwareSpecs && Object.keys(reportData.hardwareSpecs).length > 0 ? (
            React.createElement('div', { className: 'section' },
                React.createElement('h2', null, '💻 Hardware Specifications'),
                React.createElement(MetricFolder, { title: 'System Information', icon: '🖥️' },
                    React.createElement('div', { className: 'hardware-grid' },
                        Object.entries(reportData.hardwareSpecs).map(([key, value]) =>
                            React.createElement('div', { key: key, className: 'hardware-item' },
                                React.createElement('div', { className: 'hardware-item-label' }, key),
                                React.createElement('div', { className: 'hardware-item-value' }, value)
                            )
                        )
                    )
                )
            )
        ) : null,
        reportData.resourceUsage && Object.keys(reportData.resourceUsage).length > 0 ? (
            React.createElement('div', { className: 'section' },
                React.createElement('h2', null, '📊 Resource Usage'),
                React.createElement(MetricFolder, { title: 'CPU & Memory Usage', icon: '⚡' },
                    React.createElement('div', { className: 'hardware-grid' },
                        Object.entries(reportData.resourceUsage).map(([key, value]) => {
                            if (typeof value === 'object' && value !== null) {
                                return React.createElement('div', { key: key, className: 'hardware-item' },
                                    React.createElement('div', { className: 'hardware-item-label' }, key),
                                    value.CPU !== undefined ? (
                                        React.createElement('div', { style: { marginTop: '5px' } },
                                            React.createElement('strong', null, 'CPU: '), value.CPU.toFixed(2) + '%'
                                        )
                                    ) : null,
                                    value.Memory !== undefined ? (
                                        React.createElement('div', { style: { marginTop: '5px' } },
                                            React.createElement('strong', null, 'Memory: '), value.Memory.toFixed(2) + ' MB'
                                        )
                                    ) : null
                                );
                            }
                            return null;
                        })
                    )
                )
            )
        ) : null,
        React.createElement('div', { className: 'footer' },
            React.createElement('p', null,
                React.createElement('strong', null, 'MLOS Foundation'), ' - Signal. Propagate. Myelinate. 🧠'
            ),
            React.createElement('p', null, 'Generated: ', reportData.timestamp)
        )
    );
}

// Initialize when DOM and React are ready
function initApp() {
    if (typeof React === 'undefined' || typeof ReactDOM === 'undefined') {
        console.error('React or ReactDOM not loaded. Retrying...');
        setTimeout(initApp, 100);
        return;
    }
    
    if (!window.reportData) {
        console.error('reportData not found. Make sure the data script is loaded.');
        return;
    }
    
    // Debug: Log the data structure
    console.log('Report data loaded:', {
        hasRegistrationMetrics: Array.isArray(window.reportData.registrationMetrics),
        registrationMetricsCount: window.reportData.registrationMetrics ? window.reportData.registrationMetrics.length : 0,
        hasInferenceMetrics: Array.isArray(window.reportData.inferenceMetrics),
        inferenceMetricsCount: window.reportData.inferenceMetrics ? window.reportData.inferenceMetrics.length : 0,
        hasHardwareSpecs: typeof window.reportData.hardwareSpecs === 'object',
        hasResourceUsage: typeof window.reportData.resourceUsage === 'object'
    });
    
    const root = document.getElementById('root');
    if (!root) {
        console.error('Root element not found');
        return;
    }
    
    try {
        ReactDOM.render(React.createElement(App), root);
        console.log('React app rendered successfully');
    } catch (error) {
        console.error('Error rendering React app:', error);
        console.error('Error stack:', error.stack);
        root.innerHTML = '<div style="padding: 40px; text-align: center; color: #666;"><h2>Error loading report</h2><p>' + error.message + '</p><pre style="text-align: left; margin-top: 20px;">' + error.stack + '</pre></div>';
    }
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initApp);
} else {
    // Wait a bit for scripts to load
    setTimeout(initApp, 100);
}

